#!/usr/bin/env node
/**
 * dsh-openai-bridge 自检脚本 (smoke-test.mjs)
 *
 * 一键验证：
 *   1. healthz 健康检查
 *   2. /v1/models 模型列表
 *   3. 非流式补全（stream=false）
 *   4. 流式补全（SSE，验证 [DONE]）
 *   5. 工具调用（让 Agent 执行 PowerShell 命令并回传输出）
 *   6. 多轮上下文（会话记忆）
 *
 * 用法：
 *   node smoke-test.mjs              # 默认 127.0.0.1:8787
 *   node smoke-test.mjs --port 9000  # 指定端口
 *   node smoke-test.mjs --timeout 180000   # 每个请求超时（毫秒，默认 120s）
 *
 * 退出码：0 = 全部通过；1 = 有失败
 * 依赖：仅 Node 内置模块（http / crypto），与 server.mjs 风格一致。
 */

import http from 'node:http'
import crypto from 'node:crypto'

/* ------------------------- 参数解析 ------------------------- */
let port = Number(process.env.DSH_BRIDGE_PORT ?? 8787)
let timeoutMs = 120_000

const args = process.argv.slice(2)
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port') port = Number(args[i + 1] ?? 8787)
  else if (args[i] === '--timeout') timeoutMs = Number(args[i + 1] ?? 120_000)
  else if (args[i] === '--help' || args[i] === '-h') {
    console.log('用法: node smoke-test.mjs [--port 8787] [--timeout 120000]')
    process.exit(0)
  }
}

const BASE = `http://127.0.0.1:${port}`
// 独立会话，避免干扰正在使用的 Chatbox 会话
const SESSION = `smoke-${crypto.randomBytes(4).toString('hex')}`

/* ------------------------- 工具函数 ------------------------- */
let passed = 0
let failed = 0
const failures = []

function report(name, ok, detail = '') {
  const tag = ok ? '✅ PASS' : '❌ FAIL'
  console.log(`${tag}  ${name}${detail ? `\n     ${detail}` : ''}`)
  if (ok) passed++
  else {
    failed++
    failures.push(name)
  }
}

function request(path, { method = 'GET', body, headers = {}, timeout = 15_000 } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body)
    const req = http.request(
      BASE + path,
      {
        method,
        headers: {
          'Content-Type': 'application/json',
          ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
          ...headers,
        },
        timeout,
      },
      (res) => {
        let raw = ''
        res.on('data', (c) => (raw += c))
        res.on('end', () => resolve({ status: res.statusCode, body: raw }))
      },
    )
    req.on('timeout', () => req.destroy(new Error(`timeout after ${timeout}ms`)))
    req.on('error', reject)
    if (data) req.write(data)
    req.end()
  })
}

async function chat(prompt, { stream = false, session = SESSION, timeout = timeoutMs } = {}) {
  const res = await request('/v1/chat/completions', {
    method: 'POST',
    body: {
      model: 'deepseek-v4-flash',
      stream,
      messages: [{ role: 'user', content: prompt }],
    },
    headers: { 'X-DSH-Session': session },
    timeout,
  })
  return res
}

/** 解析 SSE 流文本，返回 { content, done } */
function parseSse(raw) {
  let content = ''
  let done = false
  for (const block of raw.split('\n\n')) {
    for (const line of block.split('\n')) {
      if (!line.startsWith('data:')) continue
      const payload = line.slice(5).trim()
      if (payload === '[DONE]') {
        done = true
        continue
      }
      try {
        const obj = JSON.parse(payload)
        const delta = obj.choices?.[0]?.delta
        if (delta && typeof delta.content === 'string') content += delta.content
      } catch {
        /* 忽略无法解析的行 */
      }
    }
  }
  return { content, done }
}

/* ------------------------- 测试主体 ------------------------- */
console.log(`▶ dsh-openai-bridge 自检开始  BASE=${BASE}  会话=${SESSION}\n`)

/* 1. healthz */
try {
  const res = await request('/healthz', { timeout: 10_000 })
  let ok = false
  try {
    ok = res.status === 200 && JSON.parse(res.body).status === 'ok'
  } catch {}
  report('healthz 健康检查', ok, ok ? res.body : `HTTP ${res.status} ${res.body.slice(0, 200)}`)
} catch (e) {
  report('healthz 健康检查', false, e.message)
}

/* 2. /v1/models */
try {
  const res = await request('/v1/models', { timeout: 10_000 })
  let ok = false
  try {
    const data = JSON.parse(res.body)
    ok = res.status === 200 && Array.isArray(data.data) && data.data.length > 0 && typeof data.data[0].id === 'string'
  } catch {}
  report('/v1/models 模型列表', ok, ok ? `模型: ${JSON.parse(res.body).data.map((m) => m.id).join(', ')}` : `HTTP ${res.status} ${res.body.slice(0, 200)}`)
} catch (e) {
  report('/v1/models 模型列表', false, e.message)
}

/* 3. 非流式补全 */
try {
  const res = await chat('只回复四个字：冒烟测试')
  let ok = false
  let text = ''
  try {
    const data = JSON.parse(res.body)
    text = data.choices?.[0]?.message?.content ?? ''
    ok = res.status === 200 && text.length > 0
  } catch {}
  report('非流式补全 (stream=false)', ok, ok ? `回复: ${text.slice(0, 80)}` : `HTTP ${res.status} ${res.body.slice(0, 300)}`)
} catch (e) {
  report('非流式补全 (stream=false)', false, e.message)
}

/* 4. 流式补全（SSE） */
try {
  const res = await chat('只回复四个字：流式测试', { stream: true })
  const { content, done } = parseSse(res.body)
  const ok = res.status === 200 && done && content.length > 0
  report('流式补全 (SSE + [DONE])', ok, ok ? `收到 ${content.length} 字: ${content.slice(0, 80)}` : `HTTP ${res.status} done=${done} len=${content.length}`)
} catch (e) {
  report('流式补全 (SSE + [DONE])', false, e.message)
}

/* 5. 工具调用（PowerShell 执行 + 回传输出） */
try {
  const res = await chat('用 PowerShell 执行命令：echo smoke-tool-ok-778899。回复中必须包含命令的原始输出。', { timeout: timeoutMs })
  let text = ''
  try {
    text = JSON.parse(res.body).choices?.[0]?.message?.content ?? ''
  } catch {}
  const ok = res.status === 200 && text.includes('smoke-tool-ok-778899')
  report('工具调用（pwsh 执行并回传输出）', ok, ok ? `回复: ${text.slice(0, 150)}` : `HTTP ${res.status} 回复: ${text.slice(0, 300)}`)
} catch (e) {
  report('工具调用（pwsh 执行并回传输出）', false, e.message)
}

/* 6. 多轮上下文（会话记忆） */
try {
  await chat('记住一个暗号：青苹果9527。只回复：已记住。', { timeout: timeoutMs })
  const res2 = await chat('暗号是什么？只回复暗号本身。', { timeout: timeoutMs })
  let text = ''
  try {
    text = JSON.parse(res2.body).choices?.[0]?.message?.content ?? ''
  } catch {}
  const ok = res2.status === 200 && text.includes('青苹果9527')
  report('多轮上下文（会话记忆）', ok, ok ? `回复: ${text.slice(0, 80)}` : `HTTP ${res2.status} 回复: ${text.slice(0, 300)}`)
} catch (e) {
  report('多轮上下文（会话记忆）', false, e.message)
}

/* 清理：重置冒烟测试会话 */
try {
  await chat('/clear', { timeout: 30_000 })
  console.log('ℹ 已重置冒烟测试会话')
} catch {
  console.log('ℹ 会话重置失败（不影响测试结果，可手动 /clear）')
}

/* ------------------------- 汇总 ------------------------- */
console.log(`\n════════ 结果汇总 ════════`)
console.log(`通过: ${passed}   失败: ${failed}`)
if (failed > 0) {
  console.log(`失败项: ${failures.join('、')}`)
  process.exit(1)
}
console.log('全部通过 ✅')
process.exit(0)
