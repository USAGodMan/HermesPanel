# HermesPanel

HermesPanel 是一个端口转发和流量中转管理面板，旨在为用户提供高效、易于管理的端口转发解决方案。它支持多种协议和多种数据库（SQLite、MySQL、PostgreSQL），并支持 Docker 部署。

## 主要功能

- **端口转发**：支持多种协议（如 TCP、UDP、HTTP、HTTPS 等）进行端口转发。
- **流量中转**：高效的流量中转功能，确保网络流量稳定、高效。
- **用户管理**：通过面板进行用户管理，支持权限控制和分组。
- **规则管理**：便捷的规则配置，支持批量操作和自动化管理。
- **多种数据库支持**：支持 SQLite、MySQL、PostgreSQL，适应不同规模的需求。
- **实时监控**：实时查看服务器状态、流量统计和性能数据。

## 技术栈

### 前端
- **TypeScript**：类型安全，提供更好的开发体验。
- **Vite**：快速的开发构建工具，提升开发效率。
- **React**：用于构建用户界面的库。
- **Ant Design (antd)**：优雅的 UI 组件库。

### 后端
- **Go**：高效、并发处理能力强，适合用于高性能后端开发。
- **Gin**：Go 语言的 Web 框架，提供高效的路由和中间件支持。
- **Gorm**：Go 的 ORM 库，支持 SQLite、MySQL 和 PostgreSQL。

### 数据库
- **SQLite**：适用于小型项目和轻量级应用。
- **MySQL/PostgreSQL**：适用于中大型项目，支持更高的性能和扩展性。

### 部署
- **Docker**：简化部署过程，支持跨平台运行，提供一致的环境。

## 安装与使用

### 前端
1. 克隆仓库并进入项目目录：
   ```bash
   git clone https://github.com/yourusername/HermesPanel.git
   cd HermesPanel
