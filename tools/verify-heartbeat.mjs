// Heartbeat verification: send a long task request and watch the SSE stream
// for the "task in progress" heartbeat deltas (added 2026-08-17).
const BASE = 'http://127.0.0.1:8787/v1/chat/completions'
const SESSION = 'hb-verify-' + Date.now().toString(36)

const prompt =
  '这是一个心跳功能测试。请用 PowerShell 工具执行 Start-Sleep -Seconds 60（执行期间不要输出任何文字），' +
  '等命令结束后再简短回复"长任务完成"四个字即可。'

console.log('[test] session=' + SESSION)
console.log('[test] sending streaming request, task = Start-Sleep 60s ...')

const startedAt = Date.now()
const res = await fetch(BASE, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'x-dsh-session': SESSION,
  },
  body: JSON.stringify({
    model: 'deepseek-v4-flash',
    stream: true,
    messages: [{ role: 'user', content: prompt }],
  }),
})

console.log('[test] http status = ' + res.status)
if (!res.ok || !res.body) {
  console.log('[test] FAILED to get stream')
  process.exit(1)
}

const reader = res.body.getReader()
const decoder = new TextDecoder()
let buf = ''
let heartbeats = 0
let textLen = 0
let firstByteAt = 0

function ts() {
  return ((Date.now() - startedAt) / 1000).toFixed(1) + 's'
}

while (true) {
  const { done, value } = await reader.read()
  if (done) break
  buf += decoder.decode(value, { stream: true })
  let idx
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim()
    buf = buf.slice(idx + 1)
    if (!line.startsWith('data:')) continue
    const payload = line.slice(5).trim()
    if (payload === '[DONE]') continue
    let ev
    try { ev = JSON.parse(payload) } catch { continue }
    const delta = ev.choices?.[0]?.delta
    if (!delta) continue
    if (typeof delta.content === 'string' && delta.content) {
      if (!firstByteAt) firstByteAt = Date.now()
      textLen += delta.content.length
      if (delta.content.includes('\u23f3') || delta.content.includes('任务处理中')) {
        heartbeats++
        console.log(`[test] HEARTBEAT #${heartbeats} at +${ts()}  (delta=${JSON.stringify(delta.content.slice(0, 60))})`)
      }
    }
    if (delta.reasoning_content || delta.reasoning) {
      // reasoning is not counted as text output (by design in server.mjs)
    }
  }
}

const total = ((Date.now() - startedAt) / 1000).toFixed(1)
console.log('[test] stream ended. total=' + total + 's, firstByteAt=+' + ((firstByteAt - startedAt) / 1000).toFixed(1) + 's, textLen=' + textLen + ', heartbeats=' + heartbeats)

if (heartbeats > 0) {
  console.log('[test] PASS: heartbeat feature is ACTIVE')
  process.exit(0)
} else {
  console.log('[test] FAIL: no heartbeat observed')
  process.exit(2)
}
