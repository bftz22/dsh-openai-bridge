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
import { createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
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
// 模型上下文上限（token）。deepseek-v4-flash 为 1048576；可经环境变量覆盖。
const CONTEXT_LIMIT = Number(process.env.DSH_BRIDGE_CONTEXT_LIMIT ?? 1_048_576)
// 主动重置阈值：上一轮实际输入 token 数达到 CONTEXT_LIMIT × 该比例时，
// 下一轮请求前自动重置会话，避免历史累积到超限（dsh 自带压缩常因 token
// 统计口径不一致而拦不住，故在桥接层做兜底）。0~1 之间。
const CONTEXT_RESET_RATIO = Number(process.env.DSH_BRIDGE_CONTEXT_RESET_RATIO ?? 0.72)
// 请求超时自动恢复（2026-08-16 新增，根除“运行时死亡请求永不返回”的卡死）：
// dsh 运行时（bin.js）可能在请求处理中途死亡，此时 harness.run() 永不返回也
// 不报错（无“回合结束”），客户端表现为永久转圈。本机制：
//   - 监控请求的实际输出活动：超过 REQUEST_TIMEOUT_MS（默认 5 分钟）没有任何
//     内容流出 → 触发检查；
//   - 检查运行时子进程是否还活着：
//       已死（child.exitCode != null / 无 child / spawn 失败）→ 判定卡死 →
//       关闭全部运行时（下次请求自动拉起全新运行时，会话代际+1 避开旧存档）
//       并向客户端返回明确错误，不再挂起；
//       还活着 → 判定为健康的长任务（工具执行期间无输出属正常，如批量出图/
//       文件扫描），继续等待；但超过 REQUEST_HARD_TIMEOUT_MS（默认 30 分钟）
//       仍无输出则强制恢复（防“进程活着但已卡死”的场景）。
//   两个值均可经环境变量覆盖，设为 0 = 关闭对应保护。
const REQUEST_TIMEOUT_MS = Number(process.env.DSH_BRIDGE_REQUEST_TIMEOUT_MS ?? 5 * 60 * 1000)
const REQUEST_HARD_TIMEOUT_MS = Number(process.env.DSH_BRIDGE_REQUEST_HARD_TIMEOUT_MS ?? 30 * 60 * 1000)
// 长任务进度心跳（2026-08-17 新增，让长任务"可见"）：流式请求在长时间没有文本
// 输出（如工具执行中、批量出图、文件扫描）时，周期性向 SSE 流发送进度提示
// （⏳ 任务处理中…已 N 秒，正在调用工具 X），避免 Chatbox 界面长时间无输出被
// 误判为卡死。关键设计：心跳仅在运行时子进程仍存活时发送——真正的卡死（运行时
// 已死）保持静默，请求超时恢复机制（runWithRequestTimeout）的判定不受影响；
// 心跳本身是输出活动，也会顺延"无输出超时"计时，健康长任务不再被误判。
// DSH_BRIDGE_HEARTBEAT_MS=0 可关闭；IDLE 阈值=连续无文本输出多久后开始心跳。
const HEARTBEAT_MS = Number(process.env.DSH_BRIDGE_HEARTBEAT_MS ?? 25 * 1000)
const HEARTBEAT_IDLE_MS = Number(process.env.DSH_BRIDGE_HEARTBEAT_IDLE_MS ?? 20 * 1000)
// 图片静态服务：把 ComfyUI 输出目录挂到 http://127.0.0.1:PORT/output/<文件名>，
// 让 agent 在回复里用 markdown 图片链接展示生成结果（Chatbox 可直接渲染），
// 避免把图片 base64 塞进对话上下文导致超限。
const IMAGE_OUTPUT_DIR = process.env.DSH_BRIDGE_OUTPUT_DIR ?? 'F:\\ComfyUI-aki-v3.2\\ComfyUI\\output'

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
    t = { gen: 0, busy: Promise.resolve(), lastInputTokens: 0 }
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
  t.lastInputTokens = 0
}

/**
 * 判断一个错误是否为“上下文超限”（模型 context window exceeded）。
 * dsh 的 LlmError 会带 code=CONTEXT_WINDOW_EXCEEDED；上游网关错误文本
 * 通常形如 "This model's maximum context length is … tokens …"。
 */
function isContextOverflow(err) {
  if (!err) return false
  if (err?.code === 'CONTEXT_WINDOW_EXCEEDED') return true
  const msg = [
    err?.message,
    err?.failure?.message,
    err?.name,
    typeof err === 'string' ? err : '',
  ]
    .filter(Boolean)
    .join(' ')
  return /(maximum\s+context\s+(length|window)|context_length_exceeded|CONTEXT_WINDOW_EXCEEDED)/i.test(msg)
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

  // 收集"会话目录"（直接含文件的目录）：兼容一层平铺（.sessions\<会话>）
  // 与两层结构（.sessions\<hash>\<会话>）；纯容器目录（hash 根等）不参与治理、不会被删
  const dirs = []
  const collect = (dir) => {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return // 目录不存在/不可读，跳过
    }
    if (entries.some((e) => !e.isDirectory())) {
      dirs.push(dir) // 直接含文件 = 会话目录，参与治理
      return
    }
    for (const e of entries) {
      if (e.isDirectory()) collect(join(dir, e.name))
    }
  }
  collect(SESSION_DIR)

  // 活动时间 = max(目录 mtime, 目录内所有后代文件 mtime)
  // （快照覆盖写入只刷新文件 mtime、不刷新目录 mtime，仅看目录 mtime 会误判旧）
  const activityOf = (p) => {
    let t = 0
    try { t = Math.max(t, statSync(p).mtimeMs) } catch { /* 忽略 */ }
    try {
      for (const f of readdirSync(p, { withFileTypes: true })) {
        const fp = join(p, f.name)
        try {
          t = f.isDirectory() ? Math.max(t, activityOf(fp)) : Math.max(t, statSync(fp).mtimeMs)
        } catch { /* 忽略无法 stat 的条目 */ }
      }
    } catch { /* 忽略 */ }
    return t
  }

  const scored = dirs
    .map((p) => ({ p, mtime: activityOf(p) }))
    .sort((a, b) => b.mtime - a.mtime)

  let removed = 0
  for (const d of scored.slice(MAX_SESSIONS)) {
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

const IMAGE_MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
}

/** 图片静态服务：GET /output → JSON 文件清单；GET /output/<文件> → 图片内容 */
function serveOutputFile(res, requestPath) {
  // 去掉 /output 前缀：/output 或 /output/ → 清单；/output/<文件> → 文件
  const rest = requestPath.replace(/^\/+/, '').replace(/^output\/?/, '')
  const rel = rest.split('/').filter(Boolean)
  if (rel.length === 0) {
    // 目录清单（按时间倒序，前 50 个），方便 agent 和用户确认最新生成结果
    let files
    try {
      files = readdirSync(IMAGE_OUTPUT_DIR, { withFileTypes: true })
        .filter((e) => e.isFile())
        .map((e) => {
          try {
            const st = statSync(join(IMAGE_OUTPUT_DIR, e.name))
            return { name: e.name, size: st.size, mtime: st.mtimeMs }
          } catch {
            return null
          }
        })
        .filter(Boolean)
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, 50)
    } catch {
      sendError(res, 500, `output 目录不可读: ${IMAGE_OUTPUT_DIR}`)
      return
    }
    sendJson(res, 200, { outputDir: IMAGE_OUTPUT_DIR, count: files.length, files })
    return
  }
  if (rel.length > 1) {
    sendError(res, 404, 'only top-level files under output are served')
    return
  }
  // 只允许顶层文件名，杜绝目录穿越
  const name = basename(rel[0])
  const filePath = resolve(IMAGE_OUTPUT_DIR, name)
  if (!filePath.startsWith(resolve(IMAGE_OUTPUT_DIR) + '\\') && filePath !== resolve(IMAGE_OUTPUT_DIR)) {
    sendError(res, 403, 'forbidden')
    return
  }
  let st
  try {
    st = statSync(filePath)
  } catch {
    sendError(res, 404, `file not found: ${name}`)
    return
  }
  if (!st.isFile()) {
    sendError(res, 404, `not a file: ${name}`)
    return
  }
  const ext = basename(name).slice(basename(name).lastIndexOf('.')).toLowerCase()
  res.writeHead(200, {
    ...CORS,
    'Content-Type': IMAGE_MIME[ext] ?? 'application/octet-stream',
    'Content-Length': st.size,
    'Cache-Control': 'public, max-age=3600',
  })
  createReadStream(filePath).pipe(res)
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

  // 图片静态服务：GET /output/<文件名> 返回图片；GET /output 返回文件清单。
  // 仅允许输出目录下的顶层文件（防目录穿越），方便 agent 用 markdown 展示生成结果。
  if (req.method === 'GET' && (norm === '/output' || norm.startsWith('/output/'))) {
    serveOutputFile(res, decodeURIComponent(url.pathname))
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
 *
 * 图片处理（2026-08-16 新增）：
 *  Chatbox 随消息附带的图片（image_url 内容块）不再被静默丢弃——
 *  保存到本机收件箱 DSH_BRIDGE_IMAGE_INBOX（默认 images/inbox），
 *  并把保存路径作为提示注入文本，让 Agent 用视觉技能（skills\vision）查看。
 *  仅接受 data: 协议（图片留在本机），http(s) 链接不下载（防 SSRF）。
 */
const IMAGE_INBOX_DIR = process.env.DSH_BRIDGE_IMAGE_INBOX ?? join(import.meta.dirname, 'images', 'inbox')
try { mkdirSync(IMAGE_INBOX_DIR, { recursive: true }) } catch { /* 忽略 */ }

function saveChatImage(dataUrl, seq) {
  if (typeof dataUrl !== 'string') return null
  const m = dataUrl.match(/^data:(image\/[\w.+-]+);base64,([\s\S]+)$/)
  if (!m) return null
  const extMap = { 'image/png': '.png', 'image/jpeg': '.jpg', 'image/webp': '.webp', 'image/gif': '.gif', 'image/bmp': '.bmp' }
  const ext = extMap[m[1]] ?? '.png'
  try {
    const buf = Buffer.from(m[2], 'base64')
    const name = `chatbox-${new Date().toISOString().replace(/[:.]/g, '-')}-${seq}${ext}`
    const p = join(IMAGE_INBOX_DIR, name)
    writeFileSync(p, buf)
    return p
  } catch {
    return null
  }
}

function extractText(content) {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    let parts = []
    let imgCount = 0
    for (const b of content) {
      if (typeof b === 'string') { parts.push(b); continue }
      if (b && typeof b === 'object') {
        if (typeof b.text === 'string') { parts.push(b.text); continue }
        if (typeof b.content === 'string') { parts.push(b.content); continue }
        if (b.type === 'image_url') {
          const url = typeof b.image_url === 'string' ? b.image_url : b.image_url?.url
          const saved = saveChatImage(url, ++imgCount)
          if (saved) {
            parts.push(
              `\n[系统] 用户随消息附带了一张图片，已保存至 ${saved}。` +
              `如需要查看，请调用视觉技能查看：` +
              `powershell -File C:\\Users\\Administrator\\deepseek-harness\\skills\\vision\\vision-ask.ps1 -Image "${saved}" -Question "描述这张图片的内容"`
            )
          } else {
            parts.push('\n[系统] 用户附带了图片，但未能保存（非 data 协议或解析失败）')
          }
        }
      }
    }
    return parts.join('').trim()
  }
  return ''
}

/* ------------------------------------------------------------------ */
/* 聊天补全核心逻辑                                                     */
/* ------------------------------------------------------------------ */

/** 运行时进程存活探测：true=子进程还活着（健康长任务）；false=已死/未启动（卡死）。 */
function runtimeProcessAlive(harness) {
  try {
    const client = harness?.client
    const child = client?.child
    if (!child) return false // 从未成功启动（spawn 失败或尚未拉起）
    return child.exitCode === null && child.signalCode === null && !client.spawnError
  } catch {
    return false
  }
}

/**
 * 请求超时自动恢复（2026-08-16 新增）：见 REQUEST_TIMEOUT_MS 注释。
 *  - 监测 res 输出活动：只要流里持续有内容写出，就视为请求健康推进，不超时；
 *  - 超时后先探测运行时进程：已死 → 关闭全部运行时（代际+1，新会话避开旧存档）
 *    并返回 { settled:false, error } 由调用方给客户端报错；还活着 → 视为长任务
 *    继续等待，直到超过硬上限；
 *  - fn() 正常完成/报错 → 原样返回结果（settled=true）。
 * @returns {Promise<{settled: boolean, result: *, error: Error|null}>}
 */
async function runWithRequestTimeout(ms, hardMs, fn, res, harness) {
  if (!Number.isFinite(ms) || ms <= 0) {
    return { settled: true, result: await fn(), error: null }
  }
  const hardLimit = hardMs > 0 ? hardMs : Infinity
  const origWrite = res.write.bind(res)
  let lastActivity = Date.now()
  res.write = (chunk, ...rest) => {
    lastActivity = Date.now()
    return origWrite(chunk, ...rest)
  }
  try {
    return await new Promise((resolve) => {
      let done = false
      const finish = (settled, result, error) => {
        if (done) return
        done = true
        clearTimeout(timer)
        resolve({ settled, result, error })
      }
      const startedAt = Date.now()
      let timer
      const check = () => {
        if (done) return
        const idle = Date.now() - lastActivity
        if (idle < ms) {
          // 还有输出活动，按剩余时间顺延（不重置硬上限计时）
          timer = setTimeout(check, ms - idle)
          return
        }
        const elapsed = Date.now() - startedAt
        if (runtimeProcessAlive(harness) && elapsed < hardLimit) {
          // 运行时进程还活着：大概率是健康的长任务（工具执行期间无输出属正常）
          console.warn(`[bridge] 请求已 ${Math.round(elapsed / 1000)} 秒无输出，但运行时进程仍存活，判定为长任务，继续等待（超过 ${Math.round(hardLimit / 1000)} 秒将强制恢复）`)
          timer = setTimeout(check, ms)
          return
        }
        // 运行时已死（或超过硬上限仍无输出）→ 判定卡死，自动恢复
        const reason = runtimeProcessAlive(harness) ? '超过硬上限仍无输出' : '运行时已死亡'
        console.error(`[bridge] 请求超时：${Math.round(elapsed / 1000)} 秒无输出（${reason}），自动恢复中…`)
        closeAllHarnesses().catch((e) => console.error('[bridge] 超时关闭运行时失败:', e))
        finish(false, null, new Error(
          `请求超时（${Math.round(elapsed / 1000)} 秒无响应，${reason}），已自动关闭并重置运行时；请重试（重启后首个请求冷启动 30~60 秒属正常）`,
        ))
      }
      timer = setTimeout(check, ms)
      fn().then(
        (result) => finish(true, result, null),
        (error) => finish(true, null, error),
      )
    })
  } finally {
    res.write = origWrite
  }
}

/** 运行时卡死超时：向客户端返回明确错误（保证请求一定有结果，不再永久挂起）。 */
function respondTimeout(res, model, stream, error) {
  const msg = error?.message ?? '请求超时，运行时已自动恢复，请重试（重启后首个请求冷启动 30~60 秒属正常）'
  if (stream) {
    if (!res.writableEnded) {
      try {
        writeSseDelta(res, model, `\n\n[错误] ${msg}`)
        writeSseEnd(res, model, null, 'stop')
        res.end()
      } catch {
        /* 客户端已断开 */
      }
    }
  } else if (!res.headersSent) {
    sendError(res, 504, msg, 'dsh_request_timeout')
  }
}

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
      `上下文保护：上一轮输入达到模型上限(${CONTEXT_LIMIT.toLocaleString()} tokens)的 ${Math.round(CONTEXT_RESET_RATIO * 100)}% 时会自动重置会话；`,
      '请求因上下文超限失败时也会自动重置会话并重试一次。',
      `请求超时恢复：请求 ${Math.round(REQUEST_TIMEOUT_MS / 1000)} 秒无输出且运行时已死时自动关闭并重置运行时（${REQUEST_HARD_TIMEOUT_MS > 0 ? `超过 ${Math.round(REQUEST_HARD_TIMEOUT_MS / 1000)} 秒强制恢复` : '无硬上限'}；DSH_BRIDGE_REQUEST_TIMEOUT_MS=0 关闭）。`,
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
    let harness
    try {
      harness = getHarness(model)
    } catch (err) {
      console.error('[bridge] 运行时初始化失败:', err)
      if (!res.headersSent) sendError(res, 500, `runtime init failed: ${err.message}`)
      return
    }

    // 主动防御：上一轮实际输入已接近模型上下文上限时，先重置会话再处理本轮，
    // 避免历史继续累积到超限（dsh 自带压缩常因 token 统计口径不一致而拦不住）。
    if (thread.lastInputTokens >= CONTEXT_LIMIT * CONTEXT_RESET_RATIO) {
      const pct = Math.round((thread.lastInputTokens / CONTEXT_LIMIT) * 100)
      console.log(`[bridge] 上下文防御：上一轮输入 ${thread.lastInputTokens} tokens（上限 ${CONTEXT_LIMIT} 的 ${pct}%），自动重置会话避免超限`)
      resetThread(threadKey)
    }

    // 执行一次回合；若返回 overflow=true 表示上下文超限（需要重置会话后重试）；
    // timedOut=true 表示运行时卡死超时（已自动恢复，直接向客户端返回明确错误）
    const attempt = async (sid, notice) => {
      if (stream) {
        if (notice) writeSseDelta(res, model, notice)
        const { settled, result, error } = await runWithRequestTimeout(
          REQUEST_TIMEOUT_MS, REQUEST_HARD_TIMEOUT_MS,
          () => runStreaming(harness, sid, prompt, model, res, thread),
          res, harness,
        )
        if (!settled) return { timedOut: true, error }
        if (error) throw error
        return result.overflow ? { overflow: true, error: result.error } : { overflow: false }
      }
      try {
        const { settled, result, error } = await runWithRequestTimeout(
          REQUEST_TIMEOUT_MS, REQUEST_HARD_TIMEOUT_MS,
          () => runNonStreaming(harness, sid, prompt, model, res, thread),
          res, harness,
        )
        if (!settled) return { timedOut: true, error }
        if (error) throw error
        return { overflow: false }
      } catch (err) {
        if (isContextOverflow(err)) return { overflow: true, error: err }
        throw err
      }
    }

    if (stream) writeSseHeaders(res, model)

    try {
      let outcome = await attempt(sessionIdOf(threadKey, thread))
      if (outcome.timedOut) {
        // 运行时卡死超时：已自动关闭全部运行时（下次请求自动拉起全新的），
        // 向客户端返回明确错误，保证请求一定有结果（不再永久挂起）
        console.error('[bridge] 请求超时恢复完成：已关闭运行时，向客户端返回错误（下次请求冷启动 30~60 秒属正常）')
        respondTimeout(res, model, stream, outcome.error)
        return
      }
      if (outcome.overflow) {
        // 自愈：上下文超限 → 自动重置会话 → 用同一消息重试一次
        console.log('[bridge] 上下文超限，已自动重置会话并重试一次')
        resetThread(threadKey)
        outcome = await attempt(sessionIdOf(threadKey, thread), '\n\n（上下文已超限，已自动重置会话，正在重试…）\n\n')
        if (outcome.timedOut) {
          // 重试过程中运行时卡死：同样返回明确错误，不挂起
          console.error('[bridge] 重试过程请求超时：已关闭运行时，向客户端返回错误')
          respondTimeout(res, model, stream, outcome.error)
          return
        }
        if (outcome.overflow) {
          // 重试仍超限（例如用户单条消息本身就超过上限）
          console.error('[bridge] 重置会话后重试仍超限:', outcome.error)
          const msg = `上下文超限：请求内容超过模型上限 ${CONTEXT_LIMIT.toLocaleString()} tokens（${outcome.error?.message ?? ''}）。\n可发送 /clear 重置会话，或缩短消息内容后重试。`
          if (stream) {
            writeSseDelta(res, model, `\n\n[错误] ${msg}`)
            writeSseEnd(res, model, null, 'stop')
            res.end()
          } else if (!res.headersSent) {
            sendError(res, 429, msg, 'context_length_exceeded')
          }
        }
      }
    } catch (err) {
      // 非超限错误：保证客户端一定能收到响应（不挂起）
      console.error('[bridge] dsh 执行失败:', err)
      if (stream) {
        if (!res.writableEnded) {
          try {
            writeSseDelta(res, model, `[桥接错误] ${err?.message ?? String(err)}`)
            writeSseEnd(res, model, null, 'stop')
            res.end()
          } catch {
            /* 客户端已断开 */
          }
        }
      } else if (!res.headersSent) {
        sendError(res, 500, `dsh run failed: ${err.message}`, 'dsh_run_error')
      }
    }
  })
}

/** 非流式：执行一次 dsh 回合，把结果拼成 OpenAI completion JSON 并返回。 */
async function runNonStreaming(harness, sessionId, prompt, model, res, thread) {
  const traceLines = []
  const reasoningParts = []
  const toolStats = newToolStats()
  const result = await harness.run(prompt, {
    sessionId,
    onNotification: (n) => {
      if (n.method !== 'session.event' || n.params.sessionId !== sessionId) return
      const ev = n.params.event
      if (!ev || typeof ev.type !== 'string') return
      const data = ev.data ?? {}
      if (SHOW_TOOLS && ev.type === 'tool/call') {
        noteToolCall(toolStats, data)
        if (!TOOLS_SUMMARY) traceLines.push(toolCallLine(data))
      } else if (SHOW_TOOLS && ev.type === 'tool/result') {
        noteToolResult(toolStats, data)
        if (!TOOLS_SUMMARY) traceLines.push(toolResultLine(data))
      } else if (ev.type === 'assistant/message' && data.usage) {
        thread.lastInputTokens = Number(data.usage.inputTokens ?? data.usage.promptTokens ?? 0)
      }
      if (SHOW_REASONING && ev.type === 'assistant/message') {
        // 收集最终消息里的推理块（{ type: 'reasoning', text }）
        const blocks = Array.isArray(data.message?.content) ? data.message.content : []
        for (const b of blocks) {
          if (b?.type === 'reasoning' && typeof b.text === 'string' && b.text) reasoningParts.push(b.text)
        }
      }
    },
  })

  // 超限可能以 turn/end(error) 事件返回而非抛出异常：扫描事件，命中则抛出以便上层重试
  const turnEndErr = result.events
    ?.filter((e) => e?.type === 'turn/end' && e?.data?.reason?.kind === 'error')
    .map((e) => e.data.reason.error ?? e.data.reason.failure)
    .find((err) => err && isContextOverflow(err))
  if (turnEndErr) {
    const e = turnEndErr instanceof Error ? turnEndErr : new Error(turnEndErr.message ?? String(turnEndErr))
    e.code = turnEndErr.code
    throw e
  }

  const trace = traceLines.length ? `${traceLines.join(TRACE_SEP)}\n\n` : ''
  const summary = TOOLS_SUMMARY ? toolSummaryLine(toolStats) : ''
  const content = `${trace}${result.finalResponse ?? ''}${summary ? `\n\n${summary}` : ''}`
  console.log(`[bridge] 回合结束 流式=false 最终文本=${content.length}字 工具记录=${traceLines.length}条 推理=${reasoningParts.length ? reasoningParts.join('').length + '字' : '未收集'} 输入tokens=${thread.lastInputTokens}`)
  const payload = completionJson(model, content, result)
  if (SHOW_REASONING && reasoningParts.length) {
    payload.choices[0].message.reasoning_content = reasoningParts.join('\n')
  }
  sendJson(res, 200, payload)
}

/* ------------------------------------------------------------------ */
/* 工具过程展示：把管家调用工具的过程显示在回复里（尽量贴近原生聊天观感）  */
/* 模式（环境变量 DSH_BRIDGE_SHOW_TOOLS）：                              */
/*   0   关闭：完全隐藏工具过程                                            */
/*   1   摘要（默认）：过程不刷屏，回合结束追加一行统计（最接近原生）      */
/*   2   紧凑：每个工具调用实时回显单行（🔧/✅/❌）                       */
/*   3   完整：调用参数 + 结果摘要（旧版行为，调试用）                    */
/* ------------------------------------------------------------------ */

const TOOLS_MODE = process.env.DSH_BRIDGE_SHOW_TOOLS ?? '1'
const SHOW_TOOLS = TOOLS_MODE !== '0'
const TOOLS_SUMMARY = TOOLS_MODE === '1'
const TOOLS_COMPACT = TOOLS_MODE === '2'
const TOOLS_FULL = TOOLS_MODE === '3'
const TRACE_SEP = TOOLS_FULL ? '\n\n' : '\n'

function truncate(s, n) {
  if (!s) return ''
  s = String(s)
  return s.length > n ? `${s.slice(0, n)}…` : s
}

/** 工具统计器：摘要模式用（count / byName / failCount / firstFail）。 */
function newToolStats() {
  return { count: 0, byName: {}, failCount: 0, firstFail: '' }
}

function noteToolCall(stats, data) {
  stats.count++
  const name = data?.name ?? '?'
  stats.byName[name] = (stats.byName[name] ?? 0) + 1
}

function noteToolResult(stats, data) {
  const isError = !!(data?.error || data?.message?.content?.[0]?.isError)
  if (!isError) return
  stats.failCount++
  if (!stats.firstFail) {
    const name = data?.name ?? '工具'
    const why = data?.error ? `（${data.error.name ?? ''} ${data.error.code ?? ''}）`.replace(/\s+/g, ' ').trim() : ''
    const errText = truncate(toolResultText(data?.message), 60)
    stats.firstFail = `${name}${why}${errText ? `：${errText.replace(/\s+/g, ' ')}` : ''}`
  }
}

/** 摘要模式：回合结束时追加的一行工具统计（贴近原生观感）。 */
function toolSummaryLine(stats) {
  if (!stats.count) return ''
  const names = Object.entries(stats.byName)
    .map(([n, c]) => (c > 1 ? `${n}×${c}` : n))
    .join('、')
  if (stats.failCount) {
    return `🔧 调用工具 ${stats.count} 次（${names}），失败 ${stats.failCount} 次${stats.firstFail ? `：${stats.firstFail}` : ''}`
  }
  return `🔧 调用工具 ${stats.count} 次：${names}`
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

/** tool/call 事件 → 展示文本（紧凑/完整模式用）。 */
function toolCallLine(data) {
  const name = data?.name ?? '?'
  if (!TOOLS_FULL) return `🔧 正在调用：${name}`
  const args = data?.arguments ? `\n📥 参数：${truncate(data.arguments, 200)}` : ''
  return `🔧 正在调用工具：${name}${args}`
}

/** tool/result 事件 → 展示文本（紧凑/完整模式用）。 */
function toolResultLine(data) {
  const name = data?.name ?? '工具'
  const isError = !!(data?.error || data?.message?.content?.[0]?.isError)
  const why = data?.error ? `（${data.error.name ?? ''} ${data.error.code ?? ''}）`.replace(/\s+/g, ' ').trim() : ''
  if (!TOOLS_FULL) {
    if (isError) {
      const errText = truncate(toolResultText(data?.message), 80)
      return `❌ ${name} 失败${why}${errText ? `：${errText.replace(/\s+/g, ' ')}` : ''}`
    }
    return `✅ ${name} 完成`
  }
  const summary = truncate(toolResultText(data?.message), 300)
  if (isError) {
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
async function runStreaming(harness, sessionId, prompt, model, res, thread) {
  let ended = false
  let finalText = ''
  let usage = null
  let finishReason = 'stop'
  let overflow = false
  let overflowError = null
  const toolStats = newToolStats()
  // —— 长任务进度心跳（2026-08-17 新增）——
  const heartbeatStartedAt = Date.now()   // 回合开始时刻（进度文本用）
  let heartbeatTimer = null               // 心跳定时器
  let lastTextAt = Date.now()             // 最近一次真正输出文本的时刻
  let lastToolName = ''                   // 最近一次工具调用名
  let lastToolCount = 0                   // 已完成的工具调用数
  const stopHeartbeat = () => { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null } }
  const startHeartbeat = () => {
    if (HEARTBEAT_MS <= 0 || ended) return
    heartbeatTimer = setInterval(() => {
      if (ended) return
      const idle = Date.now() - lastTextAt
      if (idle < HEARTBEAT_IDLE_MS) return        // 还在正常输出，无需心跳
      if (!runtimeProcessAlive(harness)) return   // 运行时已死 → 保持静默，交给超时恢复机制
      const elapsed = Math.round((Date.now() - heartbeatStartedAt) / 1000)
      const tool = lastToolName ? `，正在调用 ${lastToolName}${lastToolCount ? `（已完成 ${lastToolCount} 次）` : ''}` : ''
      const line = `\n\n⏳ 任务处理中…已 ${elapsed} 秒${tool}，仍在继续，请稍候\n\n`
      try { writeSseDelta(res, model, line) } catch { /* 客户端已断开 */ }
    }, HEARTBEAT_MS)
  }

  const finish = () => {
    if (ended) return
    ended = true
    stopHeartbeat()
    try {
      writeSseEnd(res, model, usage, finishReason)
      res.end()
    } catch {
      /* 客户端已断开 */
    }
  }

  try {
    startHeartbeat()
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
            lastTextAt = Date.now()
            writeSseDelta(res, model, text)
          }
        } else if (ev.type === 'assistant/chunk' && data.chunk?.type === 'reasoning-delta') {
          // 推理过程透传（默认关闭，DSH_BRIDGE_SHOW_REASONING=1 开启）
          if (SHOW_REASONING) {
            const text = data.chunk.text ?? ''
            if (text) writeSseReasoningDelta(res, model, text)
          }
        } else if (ev.type === 'assistant/chunk') {
          // 回合可能以 error 收尾（例如首次 LLM 调用即超限）：finish 块里携带失败原因
          if (data.chunk?.type === 'finish' && data.chunk?.reason?.kind === 'error') {
            const err = data.chunk.reason.failure ?? data.chunk.reason.error
            if (err && isContextOverflow(err)) {
              overflow = true
              overflowError = err
            }
          }
          if (DEBUG) console.log(`[bridge]   流块: ${data.chunk?.type ?? '未知'}`)
        } else if (ev.type === 'user/message') {
          if (DEBUG) console.log(`[bridge]   用户侧消息来源=${data.source?.kind ?? '?'}`)
        } else if (SHOW_TOOLS && ev.type === 'tool/call') {
          if (DEBUG) console.log(`[bridge]   工具调用: ${data.name} 参数=${JSON.stringify(data.arguments?.slice(0, 80))}`)
          noteToolCall(toolStats, data)
          lastToolName = data.name ?? '工具'
          if (!TOOLS_SUMMARY) {
            const line = toolCallLine(data)
            if (line) writeSseDelta(res, model, `\n\n${line}\n\n`)
          }
        } else if (SHOW_TOOLS && ev.type === 'tool/result') {
          if (DEBUG) console.log(`[bridge]   工具结果: ${data.error ? '错误' : '成功'} ${JSON.stringify(toolResultText(data.message).slice(0, 80))}`)
          noteToolResult(toolStats, data)
          lastToolCount = toolStats.count
          if (!TOOLS_SUMMARY) {
            const line = toolResultLine(data)
            if (line) writeSseDelta(res, model, `\n\n${line}\n\n`)
          }
        } else if (ev.type === 'assistant/message') {
          const blocks = Array.isArray(data.message?.content) ? data.message.content : []
          const text = blocks
            .filter((b) => b?.type === 'text')
            .map((b) => b.text ?? '')
            .join('')
          if (DEBUG) console.log(`[bridge]   assistant消息 文本=${text.length}字 内容块=${blocks.length} usage=${data.usage ? '有' : '无'}`)
          if (text) finalText = text
          if (data.usage) {
            usage = mapUsage(data.usage)
            // 记录本轮实际输入 token 数，供“主动防御”判断是否接近上下文上限
            thread.lastInputTokens = Number(data.usage.inputTokens ?? data.usage.promptTokens ?? 0)
          }
        } else if (ev.type === 'turn/end') {
          const reason = data.reason
          const kind = reason?.kind
          if (DEBUG) console.log(`[bridge]   回合结束 reason=${JSON.stringify(reason)}`)
          if (kind === 'error') {
            // 超限可能以 turn/end(error) 事件返回而非抛出异常，这里同样识别
            const err = reason.error ?? reason.failure
            if (err && isContextOverflow(err)) {
              overflow = true
              overflowError = err
            }
            finishReason = 'stop'
          } else if (kind === 'max-tokens') finishReason = 'length'
          else finishReason = 'stop'
        } else {
          if (DEBUG) console.log(`[bridge]   事件: ${ev.type}`)
        }
      },
    })
  } catch (err) {
    console.error('[bridge] dsh 执行失败:', err)
    if (isContextOverflow(err)) {
      // 上下文超限：不结束流、不写错误文本，由上层重置会话后原地重试
      overflow = true
      overflowError = err
    } else if (!ended) {
      // 传输/协议错误：打印到控制台，并把错误作为普通文本追加到流内（Chatbox 可显示）
      try {
        writeSseDelta(res, model, `[桥接错误] ${err?.message ?? String(err)}`)
      } catch {
        /* ignore */
      }
    }
  } finally {
    stopHeartbeat()
    console.log(`[bridge] 回合结束 流式=${true} 最终文本=${finalText.length}字 结束原因=${finishReason} 输入tokens=${thread.lastInputTokens}${overflow ? '（上下文超限）' : ''}`)
    // 超限时保持流打开，等待上层重置会话后重试；其余情况正常收尾
    if (!overflow) {
      // 摘要模式：最后追加一行工具统计（贴近原生观感）
      if (TOOLS_SUMMARY) {
        const summary = toolSummaryLine(toolStats)
        if (summary) {
          try { writeSseDelta(res, model, `\n\n${summary}`) } catch { /* 客户端已断开 */ }
        }
      }
      finish()
    }
  }
  return { overflow, error: overflowError }
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
  console.log(`  工具过程展示    : ${!SHOW_TOOLS ? '关' : TOOLS_SUMMARY ? '摘要（结束追加一行统计，贴近原生）' : TOOLS_COMPACT ? '紧凑（单行回显）' : '完整（参数+结果，调试用）'}`)
  console.log(`  推理透传        : ${SHOW_REASONING ? '开（reasoning_content）' : '关（DSH_BRIDGE_SHOW_REASONING=1 开启）'}`)
  console.log(`  会话存档保留    : 最新 ${MAX_SESSIONS} 个（目录=${SESSION_DIR}）`)
  console.log(`  上下文保护      : 上限 ${CONTEXT_LIMIT.toLocaleString()} tokens，超 ${Math.round(CONTEXT_RESET_RATIO * 100)}% 自动重置会话；超限请求自动重置并重试`)
  console.log(`  请求超时恢复    : ${REQUEST_TIMEOUT_MS > 0 ? `${Math.round(REQUEST_TIMEOUT_MS / 1000)} 秒无输出且运行时已死自动恢复${REQUEST_HARD_TIMEOUT_MS > 0 ? `（硬上限 ${Math.round(REQUEST_HARD_TIMEOUT_MS / 1000)} 秒）` : '（无硬上限）'}（DSH_BRIDGE_REQUEST_TIMEOUT_MS）` : '关（DSH_BRIDGE_REQUEST_TIMEOUT_MS=0）'}`)
  console.log(`  图片服务        : http://127.0.0.1:${PORT}/output/<文件名>（目录=${IMAGE_OUTPUT_DIR}）`)
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

/* 测试钩子（仅 DSH_BRIDGE_TEST_HOOKS=1 时暴露，供回归测试脚本引用内部函数；
   生产运行不设置该变量，此块不产生任何副作用） */
if (process.env.DSH_BRIDGE_TEST_HOOKS === '1') {
  globalThis.__bridgeTest = { runWithRequestTimeout, runtimeProcessAlive, closeAllHarnesses, pruneSessions }
}
