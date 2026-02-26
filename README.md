# wx-intercept

macOS 微信聊天消息防撤回插件，支持 Intel（x86_64）和 Apple Silicon（arm64）双架构。

当聊天对方撤回消息时，插件将：
1. 在**原对话窗口**中重新展示被撤回的消息内容（格式：`[撤回] 发送人: 内容`）。
2. 同时弹出一条 **macOS 系统通知**，确保消息内容不会丢失。

---

## 实现原理

插件以 **动态库（`.dylib`）** 的形式注入到微信进程中。注入后通过 Objective-C **方法交换（Method Swizzling）** 挂钩微信内部的两个关键方法：

| 被挂钩的方法 | 作用 |
|---|---|
| `-[MessageService onAddMsg:MgrType:]` | 收到新消息时将消息内容缓存到内存 |
| `-[MessageService onRevokeMsg:]`       | 检测到撤回指令时，从缓存中取回原始内容并重新展示 |

> **兼容性**：代码会依次尝试 `MessageService`、`CMessageMgr` 等多个已知类名，以兼容不同版本的微信。

---

## 目录结构

```
wx-intercept/
├── Sources/
│   ├── WxIntercept.m      # 插件主入口：挂钩安装、消息拦截、通知展示
│   ├── MessageCache.h     # 线程安全消息缓存接口
│   └── MessageCache.m     # 消息缓存实现（滚动 LRU，上限 2000 条）
├── Scripts/
│   ├── install.sh         # 安装脚本
│   └── uninstall.sh       # 卸载脚本
├── Makefile               # 构建脚本（通用二进制）
└── README.md
```

---

## 构建

### 依赖

- macOS 10.13 或更高版本
- Xcode Command Line Tools

```bash
xcode-select --install
```

### 编译

```bash
# 进入仓库目录
cd wx-intercept

# 构建（生成 WxIntercept.dylib 通用二进制）
make

# 验证架构
lipo -info WxIntercept.dylib
# 预期输出：Architectures in the fat file: WxIntercept.dylib are: x86_64 arm64
```

---

## 安装

### 额外依赖

安装 [`insert_dylib`](https://github.com/Tyilo/insert_dylib)，用于向微信二进制文件注入加载命令：

```bash
brew install insert_dylib
```

### 安装步骤

> ⚠️ **安装前请退出微信。**

```bash
make install
# 或
bash Scripts/install.sh
# 若微信不在默认路径，可指定路径：
bash Scripts/install.sh /path/to/WeChat.app
```

脚本将自动完成：
1. 将 `WxIntercept.dylib` 复制到 `WeChat.app/Contents/Frameworks/`
2. 备份原始微信二进制文件（`WeChat.wxi_backup`）
3. 使用 `insert_dylib` 在微信二进制中注入 `LC_LOAD_DYLIB` 加载命令
4. 对修改后的微信进行 ad-hoc 重新签名

### 验证安装

启动微信后，在终端中运行：

```bash
log stream --process WeChat --predicate 'eventMessage contains "[WxIntercept]"'
```

若看到如下输出，说明插件已成功加载：

```
[WxIntercept] Loaded. Initialising message recall interceptor…
[WxIntercept] Hook installation complete.
```

---

## 卸载

```bash
make uninstall
# 或
bash Scripts/uninstall.sh
```

脚本将：
1. 用备份还原原始微信二进制文件
2. 从 `WeChat.app/Contents/Frameworks/` 中删除 `WxIntercept.dylib`
3. 对还原后的二进制重新签名

---

## 注意事项

- **SIP（系统完整性保护）**：本插件使用二进制注入方式，**无需关闭 SIP**，依赖 `insert_dylib` 直接修改微信的 Mach-O 加载命令和 ad-hoc 签名。
- **微信更新**：每次微信版本更新后，需重新执行安装步骤（更新会覆盖被修改的二进制文件）。
- **隐私**：插件仅在内存中缓存最近 2000 条消息，不持久化存储，不上传任何数据。
- **免责声明**：本项目仅供学习研究，请勿用于任何违法用途。使用本插件须自行承担风险。
