# WeChat 4.x 防撤回技术分析文档

## 更新日期: 2026-02-27

---

## 1. 当前环境信息

### 1.1 WeChat 版本
- **版本号**: 4.1.7 (build 34367)
- **版本代码**: 4066645791
- **Bundle ID**: 5A4RE8SF68.com.tencent.xinWeChat
- **架构**: Universal binary (x86_64 + arm64)

### 1.2 数据目录
```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/
├── app_data/
├── xwechat_files/
│   └── {user_hash}/
│       ├── db_storage/
│       │   ├── message/          # 消息数据库 (加密)
│       │   ├── contact/
│       │   ├── session/
│       │   └── ...
│       ├── msg/
│       │   ├── attach/
│       │   ├── file/
│       │   └── video/
│       └── config/
└── mmkv/
```

---

## 2. WeChat 4.x 架构分析

### 2.1 进程架构 (Electron-like)

WeChat 4.x 采用 **多进程架构**，类似于 Electron/Chromium:

```
WeChat (主进程)
├── WeChatAppEx (渲染进程/业务逻辑)
├── WeChatAppEx Helper (GPU)
├── WeChatAppEx Helper (Network)
├── WeChatAppEx Helper (Renderer) x N
├── wxocr (OCR 服务)
├── wxplayer (媒体播放)
├── wxutility (工具服务)
└── crashpad_handler
```

### 2.2 进程通信方式

1. **Mojo IPC**: 主进程与子进程通过 Mojo 框架通信
2. **命令行参数**: `--mojo-platform-channel-handle=XXXXXX`
3. **共享内存**: 通过 `--shared-files` 标志

### 2.3 关键发现

| 项目 | 发现 |
|------|------|
| 消息处理 | 在 WeChatAppEx 进程中，不在主进程 |
| Mojo hooks | 只能捕获 2-4 字节的控制消息 |
| ObjC 类 | 主进程中无 WeChat 业务相关 ObjC 类 |
| 数据库 | 使用 WCDB + SQLCipher 加密 |

---

## 3. 已尝试方案及结果

### 3.1 方案A: Mojo IPC Hook (fishhook)

**代码位置**: `Sources/WxIntercept.m`

**Hook 函数**:
- `GetMMMojoReadInfoRequest` ✓ 工作
- `GetMMMojoReadInfoAttach` ✓ 工作
- `GetMMMojoReadInfoSync` ✓ 工作
- `GetMMMojoWriteInfoRequest` ✗ 崩溃 (SIGSEGV at 0x5)
- `SendMMMojoWriteInfo` ✗ 崩溃

**结果**: ❌ 失败
- Hooks 正常安装
- 但只能捕获小型控制消息 (len=2~4)
- 实际消息内容不经过这些函数

**日志示例**:
```
ReadRequest #1: data=0xc9be4d0a0 len=2
ReadRequest #2: data=0xc98878a40 len=4
ReadRequest #3: data=0xc9be4c3a0 len=2
```

### 3.2 方案B: ObjC Method Swizzling

**目标类** (传统 WeChat):
- `MessageService`
- `CMessageMgr`
- `CMessageWrap`

**结果**: ❌ 失败
- 类扫描发现 68,813 个类
- 0 个包含 "tencent/weixin/wechat/mmojo" 关键词
- WeChat 4.x 不使用传统 ObjC 消息类

### 3.3 方案C: revokemsg.db 监控

**数据库路径**: 
```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/
    com.tencent.xinWeChat/4.1.7.7_XXXXX/revokemsg.db
```

**结果**: ⚠️ 部分成功
- 数据库文件存在
- 最后修改时间: 2024 年
- WeChat 4.x 似乎不再使用此数据库

---

## 4. 待尝试方案

### 4.1 方案D: WeChatAppEx 进程注入

**原理**: 将 dylib 注入到 WeChatAppEx 而非 WeChat 主进程

**步骤**:
1. 找到 WeChatAppEx 可执行文件
2. 使用 insert_dylib 或修改 LC_LOAD_DYLIB
3. Hook WeChatAppEx 内部的消息处理函数

**文件位置**:
```
/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx
```

**风险**:
- WeChatAppEx 是 Chromium 框架，结构复杂
- 可能需要 hook JavaScript/V8 层

### 4.2 方案E: 数据库解密监控

**原理**: 解密 WeChat 数据库并监控变化

**数据库信息**:
- 类型: SQLCipher 加密的 SQLite
- 位置: `xwechat_files/{user}/db_storage/message/`
- 文件: `biz_message_0.db`, `biz_message_1.db` ...

**密钥获取方式** (需研究):
1. 从内存中提取
2. 从 MMKV 配置中提取
3. 逆向 WeChat 密钥生成算法

### 4.3 方案F: 网络层 Hook

**原理**: Hook 网络相关函数，在加密前捕获数据

**候选函数**:
- `send()` / `recv()`
- `SSL_write()` / `SSL_read()`
- `CFSocketSendData()` / `CFSocketCopyData()`

**风险**:
- WeChat 使用 MMTLS 自定义协议
- 数据可能在更早阶段加密

### 4.4 方案G: FSEvents 文件系统监控

**原理**: 监控 WeChat 数据目录的文件变化

**监控目标**:
```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/
```

**优点**: 不需要注入
**缺点**: 只能检测到文件变化，无法获取内容

### 4.5 方案H: Chromium DevTools Protocol

**原理**: WeChatAppEx 基于 Chromium，可能支持远程调试

**步骤**:
1. 启动 WeChat 时添加 `--remote-debugging-port=9222`
2. 通过 WebSocket 连接 DevTools
3. 注入 JavaScript 监控消息事件

**风险**:
- WeChat 可能禁用了远程调试
- 需要找到启动参数注入方式

---

## 5. libmmmojo.dylib 符号分析

### 5.1 导出函数列表

```
# Read 系列 (可安全 Hook)
_GetMMMojoReadInfoRequest
_GetMMMojoReadInfoAttach
_GetMMMojoReadInfoMethod
_GetMMMojoReadInfoSync

# Write 系列 (Hook 会崩溃)
_GetMMMojoWriteInfoRequest
_GetMMMojoWriteInfoAttach
_SendMMMojoWriteInfo
_SetMMMojoWriteInfoMessagePipe
_SetMMMojoWriteInfoResponseSync

# 配置系列
_SetMMMojoConfiguration
_SetMMMojoEnvironmentCallbacks
_SetMMMojoEnvironmentInitParams
```

### 5.2 函数签名推测

```c
// 已验证
typedef const void *(*GetMMMojoReadInfo_fn)(void *readInfo, int *outLen);

// 崩溃的函数 - 可能签名不同
// GetMMMojoWriteInfoRequest 可能需要更多参数或不同调用约定
```

---

## 6. WeChatAppEx 框架分析

### 6.1 目录结构

```
WeChatAppEx.app/Contents/
├── MacOS/
│   └── WeChatAppEx
├── Frameworks/
│   └── WeChatAppEx Framework.framework/
│       ├── Libraries/
│       │   ├── libxwcore.dylib      # 核心业务库
│       │   ├── libxwmars.dylib      # 网络库
│       │   └── ...
│       └── Helpers/
│           ├── WeChatAppEx Helper.app
│           ├── WeChatAppEx Helper (GPU).app
│           └── WeChatAppEx Helper (Renderer).app
└── Resources/
```

### 6.2 关键库

| 库名 | 用途 |
|------|------|
| libxwcore.dylib | 核心业务逻辑 |
| libxwmars.dylib | Mars 网络框架 |
| libwcdb.dylib | 数据库操作 |
| libsqlite3.dylib | SQLite |
| libcrypto.dylib | 加密 |

---

## 7. 下一步行动计划

### 优先级 1: 尝试方案D (WeChatAppEx 注入)
1. 分析 libxwcore.dylib 符号
2. 找到消息处理相关函数
3. 创建专门的 hook dylib

### 优先级 2: 尝试方案E (数据库解密)
1. 研究 WCDB 密钥存储位置
2. 尝试从 MMKV 提取密钥
3. 实现数据库监控工具

### 优先级 3: 尝试方案H (DevTools)
1. 检查 WeChatAppEx 是否支持远程调试
2. 尝试通过环境变量启用调试

---

## 8. 参考资源

### 8.1 相关项目
- WeChatTweak-macOS (旧版本适用)
- WeChatExtension-ForMac (已停更)
- fishhook (Facebook)

### 8.2 技术文档
- Mojo IPC: https://chromium.googlesource.com/chromium/src/+/master/mojo/
- WCDB: https://github.com/Tencent/wcdb
- SQLCipher: https://www.zetetic.net/sqlcipher/

---

## 9. 崩溃记录

### 9.1 Write Hook 崩溃

**症状**: WeChat 登录时闪退

**崩溃类型**: EXC_BAD_ACCESS (SIGSEGV)

**崩溃地址**: 0x5

**崩溃函数**: `hooked_GetMMMojoWriteInfoRequest`

**分析**: 
- Write 函数可能有不同的调用约定
- 参数结构可能与 Read 函数不同
- 触发时机可能在函数表未初始化时
---

## 11. 方案执行记录

### 11.1 方案D: ilink2.framework Hook (失败)

**执行时间**: 2026-02-27 15:11

**目标函数**:
- `DartCloudSession_receiveCloudNotify`
- `DartNetworkManager_subscribeNotify`  
- `DartNetworkManager_subscribeSyncMessage`

**结果**: ❌ 失败

**日志**:
```
ilink2 hook (with underscore) result=0 cloudNotify=0x0 subNotify=0x0 subSync=0x0
ilink2 hook (no underscore) result=0 cloudNotify=0x0 subNotify=0x0 subSync=0x0
```

**分析**:
- fishhook 只能 hook **被导入到当前进程的符号**
- WeChat 主进程不导入 ilink2.framework 的函数
- ilink2 函数只在 WeChatAppEx Helper 进程中被调用

**验证**:
```bash
# 检查 WeChat 是否导入 ilink2 函数
nm -u /Applications/WeChat.app/Contents/MacOS/WeChat | grep -i dart
# 结果: 空 (没有导入)
```

### 11.2 FSEvents 监控工具

**执行时间**: 2026-02-27 15:04

**工具**: `Scripts/fsmonitor.py`

**数据库分析结果**:
```
[加密] message_0.db
[加密] message_1.db
[加密] message_2.db
[加密] biz_message_0.db
[加密] session.db
... (所有数据库均为加密状态)
```

**结论**: 
- 所有消息数据库均使用 SQLCipher 加密
- 无法直接读取数据库内容
- 只能监控文件大小变化，无法获取具体内容

---

## 12. 当前技术限制总结

### 12.1 WeChat 4.x 的安全特性

| 特性 | 描述 | 影响 |
|------|------|------|
| 多进程架构 | 主进程/渲染进程分离 | 无法在主进程 hook 消息处理 |
| 数据库加密 | SQLCipher 加密 | 无法直接读取消息 |
| 进程隔离 | 独立的 WeChatAppEx 进程 | 需要单独注入 |
| 符号不导出 | 函数调用在内部完成 | fishhook 无法工作 |
| MMTLS | 自定义加密协议 | 网络层 hook 困难 |

### 12.2 可行方案评估

| 方案 | 可行性 | 难度 | 风险 |
|------|--------|------|------|
| Mojo IPC Hook | ⚠️ 部分 | 低 | 低 | 只能捕获控制消息 |
| ilink2 Hook | ❌ 不可行 | - | - | 符号不在主进程 |
| ObjC Swizzling | ❌ 不可行 | - | - | 无目标类 |
| DB 监控 | ⚠️ 有限 | 低 | 低 | 只能检测变化 |
| WeChatAppEx 注入 | ⚠️ 可能 | 高 | 高 | 需要研究 Chromium |
| 内存读取 | ⚠️ 可能 | 高 | 高 | 需要找到数据结构 |
| 屏幕监控 | ✓ 可行 | 中 | 低 | 间接方案 |

---

## 13. 推荐下一步

### 方案一: 使用用户态屏幕监控 (最实际)

1. 使用 Accessibility API 监控 WeChat 窗口
2. 检测 "xxx 撤回了一条消息" 的 UI 文本
3. 截图或 OCR 识别消息内容

**优点**: 不需要注入，稳定性高
**缺点**: 响应不够实时，依赖 UI 变化

### 方案二: 研究 WeChatAppEx 注入

1. 分析 WeChatAppEx Helper 的启动方式
2. 尝试使用 DYLD_INSERT_LIBRARIES 注入
3. Hook WeChatAppEx 内部的消息处理函数

**优点**: 能获取完整消息
**缺点**: 技术难度高，可能不稳定

### 方案三: 等待社区方案

WeChat 4.x 是较新版本，社区可能还没有成熟的防撤回方案。
可以关注:
- GitHub 相关项目更新
- 逆向工程社区讨论
---

## 10. 代码备份

### 10.1 当前 Hook 代码结构

```objc
// 工作的 Hook
static const void *hooked_GetMMMojoReadInfoRequest(void *readInfo, int *outLen) {
    if (!readInfo || !orig_GetMMMojoReadInfoRequest) {
        return orig_GetMMMojoReadInfoRequest ? 
               orig_GetMMMojoReadInfoRequest(readInfo, outLen) : NULL;
    }
    const void *data = orig_GetMMMojoReadInfoRequest(readInfo, outLen);
    int len = (data && outLen) ? *outLen : 0;
    // ... 处理数据
    return data;
}

// Hook 安装
struct rebinding rebindings[] = {
    {"GetMMMojoReadInfoRequest", hooked_GetMMMojoReadInfoRequest, &orig_GetMMMojoReadInfoRequest},
    {"GetMMMojoReadInfoAttach",  hooked_GetMMMojoReadInfoAttach,  &orig_GetMMMojoReadInfoAttach},
    {"GetMMMojoReadInfoSync",    hooked_GetMMMojoReadInfoSync,    &orig_GetMMMojoReadInfoSync},
};
rebind_symbols(rebindings, 3);
```

---

*文档将持续更新...*
