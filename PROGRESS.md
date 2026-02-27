# WxIntercept 开发进度记录

## 当前问题

微信防撤回插件 dylib 已成功注入并加载，但**防撤回功能未生效**。

---

## 已完成的分析

### 1. 崩溃问题（已修复）

- **原因**：`hookMojoIPC()` 中 hook 了 `SetMMMojoEnvironmentCallbacks`，该函数是**可变参数函数**（variadic），第二个参数是整数索引（0-6），不是指针。fishhook 替换后函数签名不匹配，导致 `libmmmojo.dylib` 内部 `KERN_PROTECTION_FAILURE` 崩溃。
- **修复**：禁用了 `hookMojoIPC()`，微信恢复正常启动。

### 2. 三种 hook 策略全部失效的原因

| 策略 | 状态 | 原因 |
|---|---|---|
| SQLite hooks (fishhook) | ❌ 失败 | `orig_sqlite3_prepare_v2 = 0x0`, `orig_sqlite3_exec = 0x0`。WeChat 4.x 使用 WCDB，sqlite3 是**静态链接**的，fishhook 只能 hook 动态链接符号 |
| ObjC swizzling | ❌ 失败 | `Hooked=0`。运行时扫描 69034 个类，无一匹配 `MessageService`/`CMessageMgr` 等。WeChat 4.x 核心逻辑已迁移至 C++/Rust |
| DB 目录监控 | ⚠️ 仅通知变化 | 只能检测到目录变更事件，无法获取具体消息内容或区分撤回操作 |

### 3. WeChat 4.x 架构分析结果

- **WeChat 版本路径**：`2.0b4.0.9`
- **二进制特征**：主二进制仅导出 `__mh_execute_header`，所有 ObjC 类/sqlite/WCDB 符号全部 strip
- **数据库**：全部加密（WCDB SQLCipher），外部无法直接读取
  - 消息库：`Message/msg_0.db` ~ `msg_9.db`
  - **撤回专用库**：`RevokeMsg/revokemsg.db`（也是加密的）
- **IPC 架构**：通过 `libmmmojo.dylib`（Chromium Mojo IPC）通信
- **ObjC 运行时**：class dump 写入 `/private/var/folders/fl/1r5zpt2s3jldwb251m3wh71r0000gn/T/wxintercept_class_dump.txt`（1.9MB，4775 个相关类），但全是 macOS 系统类，WeChat 自身几乎没有暴露 ObjC 类

### 4. libmmmojo.dylib 可用符号

```
_CreateMMMojoEnvironment
_CreateMMMojoWriteInfo
_GetMMMojoReadInfoAttach      ← 安全，2参数 (info, *outLen)
_GetMMMojoReadInfoMethod
_GetMMMojoReadInfoRequest     ← 安全，2参数 (info, *outLen)
_GetMMMojoReadInfoSync
_GetMMMojoWriteInfoAttach
_GetMMMojoWriteInfoRequest
_InitializeMMMojo
_RemoveMMMojoEnvironment
_RemoveMMMojoReadInfo
_RemoveMMMojoWriteInfo
_SendMMMojoWriteInfo          ← 安全，2参数 (env, info)
_SetMMMojoConfiguration
_SetMMMojoEnvironmentCallbacks ← ⚠️ 危险，可变参数，不能 hook
_SetMMMojoEnvironmentInitParams
_SetMMMojoWriteInfoMessagePipe
_SetMMMojoWriteInfoResponseSync
_ShutdownMMMojo
_StartMMMojoEnvironment
_StopMMMojoEnvironment
_SwapMMMojoWriteInfoCallback
_SwapMMMojoWriteInfoMessage
```

WeChat 主二进制通过动态链接导入这些符号（`nm -m` 确认为 `undefined external from libmmmojo`），因此 **fishhook 可以 hook 这些函数**。

### 5. 函数签名分析（反汇编确认）

- `GetMMMojoReadInfoRequest(void *info, int *outLen)` → 返回 `const void *`（数据指针）
- `GetMMMojoReadInfoAttach(void *info, int *outLen)` → 返回 `const void *`（附件数据指针）
- `SendMMMojoWriteInfo(void *env, void *writeInfo)` → 返回 `void *`
- 以上三个都是标准 C 调用约定，**可以安全 hook**

---

## 后续计划（下一步要做的）

### 核心策略：Hook Mojo IPC 读取函数，扫描撤回指令

1. **Hook `GetMMMojoReadInfoRequest` 和 `GetMMMojoReadInfoAttach`**
   - 这两个函数返回 IPC 消息的数据缓冲区
   - 在 hook 中，调用原始函数获取数据后，扫描返回的字节流
   - 查找撤回特征：WeChat 撤回消息 XML 包含 `<sysmsg type="revokemsg">` 或 type=10002
   - 可能是 protobuf 格式，需要搜索字节特征

2. **Hook `SendMMMojoWriteInfo`**（可选）
   - 拦截发出的 IPC 消息
   - 用于日志观察 IPC 通信模式

3. **实现逻辑**
   - 在返回的数据中搜索 `revokemsg`、`10002`、`revoke` 等字节特征
   - 提取消息发送者和内容（从 XML/protobuf 中解析）
   - 弹出 macOS 系统通知展示被撤回的消息
   - 不阻止撤回操作本身（只做通知，不修改数据流）

4. **安全注意事项**
   - **不 hook** `SetMMMojoEnvironmentCallbacks`（可变参数，会崩溃）
   - 所有 hook 函数必须严格匹配 ABI
   - hook 中不能阻塞，数据扫描应快速完成

### 具体实现步骤

- [ ] 重写 `WxIntercept.m`：移除失效的 SQLite/ObjC 策略，专注 Mojo IPC hook
- [ ] 实现 `GetMMMojoReadInfoRequest` hook：获取数据后扫描撤回特征
- [ ] 实现 `GetMMMojoReadInfoAttach` hook：同上
- [ ] 实现字节流撤回特征检测函数
- [ ] 实现消息内容提取（XML 解析或 protobuf 字段搜索）
- [ ] 测试：make clean && make && 退出微信 && bash Scripts/install.sh && 启动微信
- [ ] 验证：让对方撤回消息，检查是否收到通知

---

## 文件状态

- `Sources/WxIntercept.m` — 当前版本已禁用 Mojo hooks 和 NSNotificationCenter，待重写
- `Sources/WxIntercept.m.bak` — 原始备份
- `Sources/MessageCache.m/h` — 消息缓存，ObjC 策略用的，新方案可能不需要
- `Sources/fishhook.c/h` — fishhook 库，继续使用
- Class dump 文件：`/private/var/folders/fl/1r5zpt2s3jldwb251m3wh71r0000gn/T/wxintercept_class_dump.txt`
