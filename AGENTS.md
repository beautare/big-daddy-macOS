# Repository Guidelines

## 基本规则
- 总是用中文进行回复。
- 不要防御性编程。
- 修改后不要生成文档（markdown 等）。

## 项目结构
- `BigDaddy/`：Swift 源码，包含 macOS 菜单栏应用的核心逻辑。
- `scripts/`：构建与打包辅助脚本。
- `Package.swift`：Swift Package Manager 配置。
- `entitlements.plist`：沙盒权限声明。
- `dist/`：打包产物输出目录。

## 构建与开发命令
- `swift build`：编译调试版本。
- `swift build -c release`：编译发布版本。
- `swift test`：运行测试。
- `open Package.swift`：在 Xcode 中打开项目。

## 编码风格与命名约定
- 语言：Swift 5.9+，4 空格缩进。
- 类型名：PascalCase；方法/属性：camelCase；常量：lowerCamelCase 或 UPPER_SNAKE_CASE。
- 优先使用值类型（`struct`、`enum`），仅在需要引用语义时使用 `class`。
- 异步操作使用 Swift Concurrency（`async/await`），避免 Callback 嵌套。

## 提交规范
- 格式：`<类型>: <描述>`，例如 `feat: 添加设备绑定状态监听`、`fix: 修复心跳包发送间隔`。
- 提交前确保代码可编译且测试通过。
