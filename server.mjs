#!/usr/bin/env node
/**
 * dsh-openai-bridge — 把 DeepSeek Harness (dsh) 的 Agent 能力暴露为
 * OpenAI 兼容 HTTP API，使 Chatbox 等任意 OpenAI 兼容客户端可以直接使用。
 *
 * 工作原理：
 *   1. 通过官方 SDK (@deepseek-ai/dsh-sdk-client) 以子进程方式启动 dsh 运行时
 *      （dsh-jsonrpc-agent + cordis.yml），它是"套在模型外的完整 Agent"：
 *      模型 + 工具（bash/fs/subagent/todo…）+ 会话持久化。
 *   2. 本服务把 OpenAI 的 POST /v1/chat/completions 请求转换为 dsh 的
 *      session/prompt 调用，并把 assistant 流式事件转回 OpenAI SSE 格式。
 *   3. Chatbox 侧只需添加一个"自定义 OpenAI 兼容"提供方，指向本服务。
 *
 * 环境变量（均可选，见 README.md）：
 *   DSH_BRIDGE_PORT          监听端口，默认 8787
 *   DSH_BRIDGE_MODEL         默认模型名，默认 deepseek-v4-flash
 *   DSH_BRIDGE_PROVIDER      模型路由 provider，默认 deepseek-official
 *   DSH_BRIDGE_MAX_TOKENS    每个会话的输出 token 上限
 *   DSH_BRIDGE_SESSION_MODE  persistent（默认，跨请求保留上下文）
 *                            | per-request（每次请求新会话，无上下文）
 *   DSH_RUNTIME_COMMAND      运行时可执行文件，默认 dsh-jsonrpc-agent
 *   DSH_RUNTIME_ARGS         运行时参数（空格分隔），默认 cordis.yml
 *   DEEPSEEK_API_KEY         必填。传给运行时子进程的 DeepSeek API 密钥
 *   DSH_SYSTEM_PROMPT        Agent 的系统提示词（persona）
 *   DSH_CWD                  Agent 的工作目录（bash/fs 的根目录）
 *
 * 配置来源优先级：进程环境变量 > 同目录 .env 文件 > 默认值。
 * 零第三方运行时依赖：仅使用 node:http 与官方 dsh SDK。
 */

import http from 'node:http'
import { randomUUID } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/* ------------------------------------------------------------------ */
/* 简易 .env 加载（同目录 .env；已存在的环境变量优先，不覆盖）            */
/* ------------------------------------------------------------------ */

const BRIDGE_DIR = dirname(fileURLToPath(import.meta.url))
const ENV_FILE = join(BRIDGE_DIR, '.env')
if (existsSync(ENV_FILE)) {
  for (const line of readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/)
    if (!match) continue
    const [, key, raw] = match
    if (key in process.env) continue
    process.env[key] = raw.replace(/^["']|["']$/g, '')
  }
}

/* ------------------------------------------------------------------ */
/* dsh SDK 加载：优先 npm 包名；在 dsh 仓库根目录运行时自动 fallback     */
/* 到本地 workspace 构建产物（install 脚本采用后一种部署方式）            */
/* ------------------------------------------------------------------ */

let DeepSeekHarness

try {
  ;({ DeepSeekHarness } = await import('@deepseek-ai/dsh-sdk-client'))
} catch {
  try {
    ;({ DeepSeekHarness } = await import('./packages/sdk/client/lib/index.js'))
  } catch (err) {
    console.error('[dsh-openai-bridge] 无法加载 @deepseek-ai/dsh-sdk-client：')
    console.error('  请确认：① 在 dsh 仓库根目录运行（推荐，自动使用本地 SDK）；')
    console.error('          ② 或在独立目录运行前已执行 npm install。')
    throw err
  }
}

/* ------------------------------------------------------------------ */
/* 配置                                                               */
/* ------------------------------------------------------------------ */

const PORT = Number(process.env.DSH_BRIDGE_PORT ?? 8787)
const DEFAULT_MODEL = process.env.DSH_BRIDGE_MODEL ?? 'deepseek-v4-flash'
const PROVIDER = process.env.DSH_BRIDGE_PROVIDER ?? 'deepseek-official'
const MAX_TOKENS = process.env.DSH_BRIDGE_MAX_TOKENS
  ? Number(process.env.DSH_BRIDGE_MAX_TOKENS)
  : undefined
const SESSION_MODE = process.env.DSH_BRIDGE_SESSION_MODE ?? 'persistent'
const RUNTIME_COMMAND = process.env.DSH_RUNTIME_COMMAND ?? 'dsh-jsonrpc-agent'
const RUNTIME_ARGS = (process.env.DSH_RUNTIME_ARGS ?? 'cordis.yml')
  .split(/\s+/)
  .filter(Boolean)
const INITIAL_PERSONA = process.env.DSH_SYSTEM_PROMPT ?? ''
// 是否采纳请求携带的 system 消息作为 persona。
// Chatbox 工作模式每次都会发送一大段动态系统提示词，默认忽略（persona 用 .env 的
// DSH_SYSTEM_PROMPT），避免每次请求都重建运行时、引发会话存档冲突。需要时设为 1。
const USE_SYSTEM_PROMPT = process.env.DSH_BRIDGE_USE_SYSTEM_PROMPT === '1'
// 是否透传推理过程：dsh 的 reasoning-delta 事件 → OpenAI SSE 的
// delta.reasoning_content（非标准字段，DeepSeek 官方 API 同款命名）。
// Chatbox 等客户端默认不显示该字段，但保留数据以便未来兼容；默认关闭。
const SHOW_REASONING = process.env.DSH_BRIDGE_SHOW_REASONING === '1'
// 会话存档治理：.sessions/ 目录最多保留的最新会话数（按修改时间），
// 启动时 / 每次 /clear /new 时 / 每小时自动清理超出的旧存档。
const SESSION_DIR = process.env.DSH_BRIDGE_SESSION_DIR ?? join(process.cwd(), '.sessions')
const MAX_SESSIONS = Number(process.env.DSH_BRIDGE_MAX_SESSIONS ?? 20)
// 本次桥实例的随机前缀：每次启动都会换新，保证会话 ID 不与磁盘上的旧存档冲突
const SESSION_PREFIX = `chatbox-${randomUUID().slice(0, 8)}`
// 调试模式：设为 1 时输出每条会话事件等详细日志（排查问题时开启）
const DEBUG = process.env.DSH_BRIDGE_DEBUG === '1'

if (!process.env.DEEPSEEK_API_KEY) {
  console.warn('[dsh-openai-bridge] 警告：未设置 DEEPSEEK_API_KEY，运行时将无法调用模型。')
}

/* ------------------------------------------------------------------ */
/* 运行时管理：一个 DeepSeekHarness 实例 = 一个 dsh 运行时子进程        */
/* provider/model 在 initialize 握手时固定，因此按模型缓存实例          */
/* ------------------------------------------------------------------ */

/** @type {Map<string, DeepSeekHarness>} */
const harnesses = new Map()
let currentPersona = INITIAL_PERSONA

/** 构建子进程环境：SDK 的 launch.env 会整体替换子进程环境，必须带上全部所需变量 */
function childEnv() {
  const env = {
    ...process.env,
    DEEPSEEK_API_KEY: process.env.DEEPSEEK_API_KEY ?? '',
  }
  // 仅在显式设置时注入 persona；留空则交给 cordis.yml 使用默认 persona
  if (currentPersona) env.DSH_SYSTEM_PROMPT = currentPersona
  return env
}

function getHarness(model) {
  const key = model ?? DEFAULT_MODEL
  let harness = harnesses.get(key)
  if (!harness) {
    harness = new DeepSeekHarness({
      launch: {
        command: RUNTIME_COMMAND,
        args: RUNTIME_ARGS,
        env: childEnv(),
      },
      provider: PROVIDER,
      model: key,
      ...(MAX_TOKENS === undefined ? {} : { maxTokens: MAX_TOKENS }),
    })
    harnesses.set(key, harness)
  }
  return harness
}

/** 运行时代际：每次关闭全部运行时后 +1，配合随机前缀让新会话避开磁盘旧存档 */
let runtimeEpoch = 0

/** 关闭全部运行时（模型/系统提示词变化、/clear、退出时调用） */
async function closeAllHarnesses() {
  const all = [...harnesses.values()]
  harnesses.clear()
  runtimeEpoch += 1
  await Promise.allSettled(all.map((h) => h.close()))
}

/* ------------------------------------------------------------------ */
/* 会话管理：threadKey → dsh session id                                */
/* ------------------------------------------------------------------ */

/**
 * @type {Map<string, { gen: number, busy: Promise<void> }>}
 */
const threads = new Map()

function getThread(threadKey) {
  let t = threads.get(threadKey)
  if (!t) {
    t = { gen: 0, busy: Promise.resolve() }
    threads.set(threadKey, t)
  }
  return t
}

/** 会话 ID：含随机前缀+代际号，运行时重启/会话重置后自动换新，不与磁盘旧存档冲突 */
function sessionIdOf(threadKey, t) {
  return `${SESSION_PREFIX}-${threadKey}-e${runtimeEpoch}-g${t.gen}`
}

/** 重置某个线程的会话（旧的 dsh session 成为孤儿，不再被加载） */
function resetThread(threadKey) {
  const t = threads.get(threadKey)
  if (!t) return
  t.gen += 1
}

function resolveThreadKey(req) {
  const header = req.headers['x-dsh-session']
  if (header) return String(header).slice(0, 128)
  if (SESSION_MODE === 'per-request') return randomUUID()
  return 'default'
}

/** 简单互斥：同一线程的请求串行执行 */
function withThreadLock(thread, fn) {
  const run = thread.busy.then(fn, fn)
  // 链上追加，但把错误吞掉以免毒化后续请求
  thread.busy = run.then(
    () => undefined,
    () => undefined,
  )
  return run
}

/* ------------------------------------------------------------------ */
/* 会话存档治理：.sessions/ 无界增长 → 只保留最新的 MAX_SESSIONS 个        */
/* ------------------------------------------------------------------ */

/**
 * 清理 .sessions/ 下超出保留数量的旧会话存档（按目录修改时间排序）。
 * 只删除目录；当前会话永远是最新的，不会被误删。
 * @returns {number} 删除的目录数量
 */
function pruneSessions() {
  if (!Number.isFinite(MAX_SESSIONS) || MAX_SESSIONS < 1) return 0
  let entries
  try {
    entries = readdirSync(SESSION_DIR, { withFileTypes: true })
  } catch {
    return 0 // 目录不存在/不可读，无需清理
  }
  const dirs = entries
    .filter((e) => e.isDirectory())
    .map((e) => {
      const p = join(SESSION_DIR, e.name)
      let mtime = 0
      try {
        mtime = statSync(p).mtimeMs
      } catch {
        /* 忽略无法 stat 的目录 */
      }
      return { p, mtime }
    })
    .sort((a, b) => b.mtime - a.mtime)

  let removed = 0
  for (const d of dirs.slice(MAX_SESSIONS)) {
    try {
      rmSync(d.p, { recursive: true, force: true })
      removed++
    } catch (err) {
      console.error(`[bridge] 清理会话存档失败: ${d.p}: ${err.message}`)
    }
  }
  if (removed) {
    console.log(`[bridge] 会话存档治理: 清理 ${removed} 个旧存档（保留最新 ${MAX_SESSIONS} 个，目录=${SESSION_DIR}）`)
  }
  return removed
}

/* ------------------------------------------------------------------ */
/* OpenAI 兼容 HTTP 层                                                 */
/* ------------------------------------------------------------------ */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-DSH-Session',
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    ...CORS,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  })
  res.end(body)
}

function sendError(res, status, message, type = 'dsh_bridge_error') {
  sendJson(res, status, { error: { message, type, code: status } })
}

/** 读取请求体（限制 8MB） */
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > 8 * 1024 * 1024) {
        reject(new Error('request body too large'))
        req.destroy()
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`)
  const path = url.pathname
  // 路径归一化：去掉尾部斜杠，兼容不同客户端拼路径的方式
  // （有的客户端发 /v1/chat/completions，有的只发 /v1，有的不带 /v1 前缀）
  const norm = path.replace(/\/+$/, '')
  const isChatCompletions =
    norm === '/v1/chat/completions' || norm === '/v1' || norm === '/chat/completions' || norm === ''
  const isModels = norm === '/v1/models' || norm === '/models'

  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS)
    res.end()
    return
  }

  if (req.method === 'GET' && norm === '/healthz') {
    sendJson(res, 200, { status: 'ok', harnesses: harnesses.size })
    return
  }

  if (req.method === 'GET' && isModels) {
    sendJson(res, 200, {
      object: 'list',
      data: [
        {
          id: DEFAULT_MODEL,
          object: 'model',
          created: 0,
          owned_by: 'deepseek-harness',
        },
      ],
    })
    return
  }

  if (req.method === 'POST' && isChatCompletions) {
    await handleChatCompletion(req, res)
    return
  }

  sendError(res, 404, `unknown route: ${req.method} ${path}（请确认 Chatbox 里 API 域名填 http://127.0.0.1:8787，API 路径填 /v1）`)
})

/**
 * 从消息内容中提取纯文本。兼容 OpenAI 的两种写法：
 *  - content: "字符串"
 *  - content: [{ type: 'text', text: '...' }, ...]（内容块数组）
 */
function extractText(content) {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (typeof b === 'string') return b
        if (b && typeof b === 'object') {
          if (typeof b.text === 'string') return b.text
          if (typeof b.content === 'string') return b.content
        }
        return ''
      })
      .join('')
      .trim()
  }
  return ''
}

/* ------------------------------------------------------------------ */
/* 聊天补全核心逻辑                                                     */
/* ------------------------------------------------------------------ */

async function handleChatCompletion(req, res) {
  let body
  try {
    body = JSON.parse(await readBody(req))
  } catch {
    sendError(res, 400, 'invalid JSON body')
    return
  }

  const model = typeof body.model === 'string' ? body.model : DEFAULT_MODEL
  const messages = Array.isArray(body.messages) ? body.messages : []
  const stream = body.stream === true

  // 消息结构日志：帮助排查 Chatbox 不同模式下的消息格式差异（仅调试模式）
  if (DEBUG) {
    console.log(
      '[bridge] 消息结构: ' +
        JSON.stringify(messages.map((m) => ({ role: m?.role, 类型: typeof m?.content, 长度: Array.isArray(m?.content) ? m.content.length : (m?.content ?? '').length }))),
    )
  }

  const userMessages = messages.filter((m) => m && m.role === 'user' && extractText(m.content))
  if (userMessages.length === 0) {
    sendError(res, 400, 'no user message found in messages（Chatbox工作模式下请确认发送的是普通文本消息）')
    return
  }
  const prompt = extractText(userMessages[userMessages.length - 1].content)

  // 请求日志：每个请求都会在桥的窗口打印一行，便于排查
  console.log(
    `[bridge] 收到请求 model=${model} 流式=${stream} 会话=${resolveThreadKey(req)} 内容=${JSON.stringify(prompt.slice(0, 60))}${prompt.length > 60 ? '…' : ''}`,
  )

  // 系统提示词：仅当开启 DSH_BRIDGE_USE_SYSTEM_PROMPT=1 时才采纳请求中的 system 消息。
  // Chatbox 工作模式每次都会发送大段动态系统提示词，默认忽略（persona 来自 .env 的
  // DSH_SYSTEM_PROMPT），避免每次请求都重建运行时、引发会话存档冲突。
  let systemContent = ''
  if (USE_SYSTEM_PROMPT) {
    systemContent = messages
      .filter((m) => m && m.role === 'system')
      .map((m) => extractText(m.content))
      .filter(Boolean)
      .join('\n')
      .trim()
    if (systemContent && DEBUG) {
      console.log(`[bridge] 系统提示词 ${systemContent.length}字 前100字=${JSON.stringify(systemContent.slice(0, 100))}`)
    }
    if (systemContent && systemContent !== currentPersona) {
      currentPersona = systemContent
      await closeAllHarnesses()
      console.log('[dsh-openai-bridge] 系统提示词变化，已重建运行时')
    }
  }

  // 会话管理
  const threadKey = resolveThreadKey(req)
  const thread = getThread(threadKey)

  // 特殊命令：重置会话
  const trimmed = prompt.trim()
  if (trimmed === '/clear' || trimmed === '/new') {
    resetThread(threadKey)
    pruneSessions() // 顺带治理会话存档
    const reply = '会话已重置。这是一个全新的 dsh 会话，之前的上下文已清空。'
    if (stream) {
      writeSseHeaders(res, model)
      writeSseDelta(res, model, reply)
      writeSseEnd(res, model, { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 })
      res.end()
    } else {
      sendJson(res, 200, completionJson(model, reply))
    }
    return
  }
  if (trimmed === '/help') {
    const reply = [
      '可用命令：',
      '  /clear 或 /new  — 重置当前会话上下文',
      '  /help          — 显示本帮助',
      '',
      '其余消息会直接交给 dsh Agent 执行（可调用 bash / 文件系统 / 子代理等工具）。',
      '系统提示词：首次请求携带 system 消息时会自动应用（并触发一次运行时重建）。',
    ].join('\n')
    if (stream) {
      writeSseHeaders(res, model)
      writeSseDelta(res, model, reply)
      writeSseEnd(res, model, { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 })
      res.end()
    } else {
      sendJson(res, 200, completionJson(model, reply))
    }
    return
  }

  // 执行一次 dsh agent 回合（含工具调用循环），并把结果转回 OpenAI 格式
  await withThreadLock(thread, async () => {
    const sessionId = sessionIdOf(threadKey, thread)
    let harness
    try {
      harness = getHarness(model)
    } catch (err) {
      console.error('[bridge] 运行时初始化失败:', err)
      if (!res.headersSent) sendError(res, 500, `runtime init failed: ${err.message}`)
      return
    }

    if (stream) {
      writeSseHeaders(res, model)
      await runStreaming(harness, sessionId, prompt, model, res)
    } else {
      try {
        const traceLines = []
        const reasoningParts = []
        const result = await harness.run(prompt, {
          sessionId,
          onNotification: (n) => {
            if (n.method !== 'session.event' || n.params.sessionId !== sessionId) return
            const ev = n.params.event
            if (!ev || typeof ev.type !== 'string') return
            const data = ev.data ?? {}
            if (SHOW_TOOLS && ev.type === 'tool/call') traceLines.push(toolCallLine(data))
            else if (SHOW_TOOLS && ev.type === 'tool/result') traceLines.push(toolResultLine(data))
            else if (SHOW_REASONING && ev.type === 'assistant/message') {
              // 收集最终消息里的推理块（{ type: 'reasoning', text }）
              const blocks = Array.isArray(data.message?.content) ? data.message.content : []
              for (const b of blocks) {
                if (b?.type === 'reasoning' && typeof b.text === 'string' && b.text) reasoningParts.push(b.text)
              }
            }
          },
        })
        const trace = traceLines.length ? `${traceLines.join('\n\n')}\n\n` : ''
        const content = `${trace}${result.finalResponse ?? ''}`
        console.log(`[bridge] 回合结束 流式=false 最终文本=${content.length}字 工具记录=${traceLines.length}条 推理=${reasoningParts.length ? reasoningParts.join('').length + '字' : '未收集'}`)
        const payload = completionJson(model, content, result)
        if (SHOW_REASONING && reasoningParts.length) {
          payload.choices[0].message.reasoning_content = reasoningParts.join('\n')
        }
        sendJson(res, 200, payload)
      } catch (err) {
        console.error('[bridge] dsh 执行失败:', err)
        if (!res.headersSent) {
          sendError(res, 500, `dsh run failed: ${err.message}`, 'dsh_run_error')
        }
      }
    }
  })
}

/* ------------------------------------------------------------------ */
/* 工具过程展示：把管家调用工具的过程实时显示在回复里                    */
/* （默认开启；环境变量 DSH_BRIDGE_SHOW_TOOLS=0 可关闭）                */
/* ------------------------------------------------------------------ */

const SHOW_TOOLS = process.env.DSH_BRIDGE_SHOW_TOOLS !== '0'

function truncate(s, n) {
  if (!s) return ''
  s = String(s)
  return s.length > n ? `${s.slice(0, n)}…` : s
}

/** 从 tool/result 事件的 message 中提取可读文本（ToolResultBlock → text blocks）。 */
function toolResultText(message) {
  const blocks = message?.content
  if (!Array.isArray(blocks) || !blocks.length) return ''
  const b = blocks[0]
  if (b?.type === 'tool-result') {
    const c = b.content
    if (Array.isArray(c)) return c.map((x) => (x && x.type === 'text' ? x.text : '')).join('\n').trim()
    if (typeof c === 'string') return c.trim()
  }
  return ''
}

/** tool/call 事件 → 展示文本。 */
function toolCallLine(data) {
  const name = data?.name ?? '?'
  const args = data?.arguments ? `\n📥 参数：${truncate(data.arguments, 200)}` : ''
  return `🔧 正在调用工具：${name}${args}`
}

/** tool/result 事件 → 展示文本。 */
function toolResultLine(data) {
  const isError = !!(data?.error || data?.message?.content?.[0]?.isError)
  const summary = truncate(toolResultText(data?.message), 300)
  if (isError) {
    const why = data?.error ? `（${data.error.name ?? ''} ${data.error.code ?? ''}）`.replace(/\s+/g, ' ').trim() : ''
    return `❌ 工具执行失败${why}${summary ? `\n${summary}` : ''}`
  }
  return `✅ 工具执行完成${summary ? `\n${summary}` : ''}`
}

/* ------------------------------------------------------------------ */
/* 流式输出：把 dsh 会话事件流转换为 OpenAI SSE                          */
/* ------------------------------------------------------------------ */

function writeSseHeaders(res, model) {
  res.writeHead(200, {
    ...CORS,
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  })
  // 首个分片：声明 assistant 角色
  res.write(
    sse({
      id: `chatcmpl-${randomUUID().replaceAll('-', '')}`,
      object: 'chat.completion.chunk',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }],
    }),
  )
}

function sse(payload) {
  return `data: ${JSON.stringify(payload)}\n\n`
}

function writeSseDelta(res, model, text) {
  if (!text) return
  res.write(
    sse({
      object: 'chat.completion.chunk',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, delta: { content: text }, finish_reason: null }],
    }),
  )
}

/** 推理过程分片：DeepSeek 官方 API 同款非标准字段 delta.reasoning_content */
function writeSseReasoningDelta(res, model, text) {
  if (!text) return
  res.write(
    sse({
      object: 'chat.completion.chunk',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, delta: { reasoning_content: text }, finish_reason: null }],
    }),
  )
}

function writeSseEnd(res, model, usage, finishReason = 'stop') {
  res.write(
    sse({
      object: 'chat.completion.chunk',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, delta: {}, finish_reason: finishReason }],
      usage: usage ?? null,
    }),
  )
  res.write('data: [DONE]\n\n')
}

/**
 * 运行一次 dsh 回合并实时转发文本流。
 * 事件映射：
 *   assistant/chunk { type: 'text-delta' }  → OpenAI delta.content
 *   assistant/message                       → 兜底完整文本 + usage
 *   turn/end                                → finish_reason
 *   session.status idle                     → 结束流
 */
async function runStreaming(harness, sessionId, prompt, model, res) {
  let ended = false
  let finalText = ''
  let usage = null
  let finishReason = 'stop'

  const finish = () => {
    if (ended) return
    ended = true
    try {
      writeSseEnd(res, model, usage, finishReason)
      res.end()
    } catch {
      /* 客户端已断开 */
    }
  }

  try {
    await harness.run(prompt, {
      sessionId,
      onNotification: (n) => {
        if (ended) return
        if (n.method !== 'session.event' || n.params.sessionId !== sessionId) return
        const ev = n.params.event
        if (!ev || typeof ev.type !== 'string') return
        const data = ev.data ?? {}

        if (ev.type === 'assistant/chunk' && data.chunk?.type === 'text-delta') {
          const text = data.chunk.text ?? ''
          if (text) {
            finalText += text
            writeSseDelta(res, model, text)
          }
        } else if (ev.type === 'assistant/chunk' && data.chunk?.type === 'reasoning-delta') {
          // 推理过程透传（默认关闭，DSH_BRIDGE_SHOW_REASONING=1 开启）
          if (SHOW_REASONING) {
            const text = data.chunk.text ?? ''
            if (text) writeSseReasoningDelta(res, model, text)
          }
        } else if (ev.type === 'assistant/chunk') {
          if (DEBUG) console.log(`[bridge]   流块: ${data.chunk?.type ?? '未知'}`)
        } else if (ev.type === 'user/message') {
          if (DEBUG) console.log(`[bridge]   用户侧消息来源=${data.source?.kind ?? '?'}`)
        } else if (SHOW_TOOLS && ev.type === 'tool/call') {
          if (DEBUG) console.log(`[bridge]   工具调用: ${data.name} 参数=${JSON.stringify(data.arguments?.slice(0, 80))}`)
          const line = toolCallLine(data)
          if (line) writeSseDelta(res, model, `\n\n${line}\n\n`)
        } else if (SHOW_TOOLS && ev.type === 'tool/result') {
          if (DEBUG) console.log(`[bridge]   工具结果: ${data.error ? '错误' : '成功'} ${JSON.stringify(toolResultText(data.message).slice(0, 80))}`)
          const line = toolResultLine(data)
          if (line) writeSseDelta(res, model, `\n\n${line}\n\n`)
        } else if (ev.type === 'assistant/message') {
          const blocks = Array.isArray(data.message?.content) ? data.message.content : []
          const text = blocks
            .filter((b) => b?.type === 'text')
            .map((b) => b.text ?? '')
            .join('')
          if (DEBUG) console.log(`[bridge]   assistant消息 文本=${text.length}字 内容块=${blocks.length} usage=${data.usage ? '有' : '无'}`)
          if (text) finalText = text
          if (data.usage) usage = mapUsage(data.usage)
        } else if (ev.type === 'turn/end') {
          const kind = data.reason?.kind
          if (DEBUG) console.log(`[bridge]   回合结束 reason=${JSON.stringify(data.reason)}`)
          if (kind === 'max-tokens') finishReason = 'length'
          else if (kind === 'error') finishReason = 'stop'
          else finishReason = 'stop'
        } else {
          if (DEBUG) console.log(`[bridge]   事件: ${ev.type}`)
        }
      },
    })
  } catch (err) {
    // 传输/协议错误：打印到控制台，并把错误作为普通文本追加到流内（Chatbox 可显示）
    console.error('[bridge] dsh 执行失败:', err)
    if (!ended) {
      try {
        writeSseDelta(res, model, `[桥接错误] ${err?.message ?? String(err)}`)
      } catch {
        /* ignore */
      }
    }
  } finally {
    console.log(`[bridge] 回合结束 流式=${true} 最终文本=${finalText.length}字 结束原因=${finishReason}`)
    finish()
  }
}

/* ------------------------------------------------------------------ */
/* 输出格式辅助                                                         */
/* ------------------------------------------------------------------ */

function mapUsage(u) {
  if (!u || typeof u !== 'object') return null
  const input = Number(u.inputTokens ?? u.promptTokens ?? 0)
  const cached = Number(u.cachedInputTokens ?? 0)
  const output = Number(u.outputTokens ?? u.completionTokens ?? 0)
  return {
    prompt_tokens: input + cached,
    completion_tokens: output,
    total_tokens: input + cached + output,
  }
}

function completionJson(model, content, result) {
  const usage = result ? mapUsage(result.events.find((e) => e?.type === 'assistant/message')?.data?.usage) : null
  return {
    id: `chatcmpl-${randomUUID().replaceAll('-', '')}`,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        message: { role: 'assistant', content },
        finish_reason: 'stop',
      },
    ],
    usage,
  }
}

/* ------------------------------------------------------------------ */
/* 启动与优雅退出                                                       */
/* ------------------------------------------------------------------ */

server.listen(PORT, '127.0.0.1', () => {
  console.log('==============================================================')
  console.log('  dsh-openai-bridge 已启动')
  console.log(`  OpenAI 兼容端点 : http://127.0.0.1:${PORT}/v1`)
  console.log(`  模型            : ${DEFAULT_MODEL}`)
  console.log(`  运行时          : ${RUNTIME_COMMAND} ${RUNTIME_ARGS.join(' ')}`)
  console.log(`  会话模式        : ${SESSION_MODE}`)
  console.log(`  工具过程展示    : ${SHOW_TOOLS ? '开（每次工具调用都会显示在回复中）' : '关'}`)
  console.log(`  推理透传        : ${SHOW_REASONING ? '开（reasoning_content）' : '关（DSH_BRIDGE_SHOW_REASONING=1 开启）'}`)
  console.log(`  会话存档保留    : 最新 ${MAX_SESSIONS} 个（目录=${SESSION_DIR}）`)
  console.log('')
  console.log('  Chatbox 配置：设置 → 模型提供方 → 添加自定义 OpenAI 兼容')
  console.log(`  API 地址：http://127.0.0.1:${PORT}/v1   API 密钥：任意非空值`)
  console.log('==============================================================')
  pruneSessions() // 启动时清理一次
  setInterval(pruneSessions, 3600 * 1000).unref() // 之后每小时清理一次
})

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    console.log(`\n[dsh-openai-bridge] 收到 ${sig}，正在关闭运行时…`)
    await closeAllHarnesses()
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 3000).unref()
  })
}
