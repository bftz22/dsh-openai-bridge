# Cherry Studio 连接 AI 管家（桥）配置说明

> Cherry Studio 是开源 OpenAI 兼容客户端（https://cherry-ai.com ），桥（dsh-openai-bridge）
> 提供标准 OpenAI 兼容 API（`http://127.0.0.1:8787/v1`），**桥侧零改动**。
> 本说明已在真实 Cherry Studio 2.0.5 界面验证（设置入口、菜单文字均与截图一致）。

---

## 方法一：改内置 DeepSeek 提供商（推荐，最省事）

Cherry Studio **内置了 DeepSeek 提供商**，只需把地址改成桥：

1. 打开 Cherry Studio（首次启动的引导页直接点"开始使用"跳过即可）
2. `Ctrl + ,` 打开设置（或点左侧栏底部设置图标）→ 左侧点 **模型服务**
3. 找到 **DeepSeek**（默认展开，API 地址显示 `https://api.deepseek.com`）
4. 把 **API 地址** 改成：`http://127.0.0.1:8787/v1`
5. 把 **API 密钥** 填：`local`（随便填，桥不校验）
6. 模型列表里应有 `deepseek-v4-flash`（若为空，点"获取模型列表"，桥已支持自动拉取）
7. **保存** → **新建对话**（旧对话可能仍绑着旧配置）→ 顶部模型选择器确认选中 `deepseek-v4-flash` → 发"你好"测试

## 方法二：添加 OpenAI 类型提供商（不想动内置项时）

1. 设置 → 模型服务 → 点 **添加**
2. 类型选 **OpenAI** → 名称填：`AI管家`
3. API 地址：`http://127.0.0.1:8787/v1`
4. API 密钥：`local`
5. 添加模型：`deepseek-v4-flash`
6. 保存 → 新建对话 → 模型选择器选 `AI管家 / deepseek-v4-flash` → 发"你好"测试

> 推荐优先用方法二：OpenAI 类型提供商默认走 `/v1/chat/completions` 通道（桥的标准协议），
> 可避开内置 DeepSeek 提供商"OpenAI Responses"通道的路由问题。

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `Authentication Fails, Your api key is invalid`（401） | 请求发到了 DeepSeek 官方（API 地址没改成桥） | 检查 API 地址必须是 `http://127.0.0.1:8787/v1`；若用的是内置 DeepSeek，确认"OpenAI 默认 / OpenAI Responses"地址都改掉，或改用方法二 |
| `net::ERR_NETWORK_ACCESS_DENIED` | 系统代理 / 安全软件拦截本地端口 | 关闭系统代理（设置 → 网络和 Internet → 代理）；安全软件把 Cherry Studio 加白名单或临时退出 |
| 一直转圈无回复 | 首次冷启动 30~60 秒 | 正常，耐心等；超过 2 分钟跑 `tools/check-bridge.bat` 三层自检 |
| 模型选择器里没有 `deepseek-v4-flash` | 模型列表未拉取 | 点"获取模型列表"，或手动"添加模型"填 `deepseek-v4-flash` |

## 验证连的是桥而不是官方

- 让 AI 执行 `whoami`：有工具调用（"正在执行命令"字样）并返回真实结果 = 连的是桥
- 问"你是谁"：桥会回答"AI 管家"类身份；官方模型自称 DeepSeek
- 检查 API 地址：必须是 `http://127.0.0.1:8787/v1`，而非 `https://api.deepseek.com`
