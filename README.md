<p align="right"><a href="./README.en.md">English</a> | 中文</p>

---
# HermesPanel - 高性能流量调度与端口转发管理面板
<p align="center">
  <strong>一个现代化、功能丰富的流量中转与端口转发管理面板，专为需要高可用性、灵活性和精细化流量控制的场景而设计。</strong>
</p>

<p align="center">
  <a href="https://github.com/Hermes-Panel/hermes/releases"><img src="https://img.shields.io/github/v/release/Hermes-Panel/hermes.svg" alt="Latest Release"></a>
  <a href="#"><img src="https://img.shields.io/badge/Go-1.21%2B-blue.svg" alt="Go Version"></a>
  <a href="#"><img src="https://img.shields.io/badge/React-18%2B-blue.svg" alt="React Version"></a>
  <a href="#"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

---

**HermesPanel** 不仅仅是一个简单的端口转发工具。它是一个强大的流量调度平台，赋予您对网络流量的完全控制权。无论是为您的服务实现高可用性、进行 A/B 测试，还是为多区域部署提供智能路由，HermesPanel 都能轻松应对。

## ✨ 核心功能亮点

- **多协议支持**: 支持 **TCP** 和 **UDP** 的直接转发与安全隧道转发。
- **高可用性保障**:
  - **✅ 健康检查**: 自动探测后端服务健康状况，实时感知服务可用性。
  - **✅ 自动故障转移**: 自动剔除故障节点，将流量无缝切换至健康服务，确保业务连续性。
- **高级负载均衡**:
  - **🔀 多种策略**: 内置**随机**、**轮询**、**平滑加权轮询**、**最少连接数**和 **IP 哈希**五种负载均衡算法。
  - **⚖️ 权重配置**: 允许为后端服务设置不同权重，实现精细化的流量分配。
- **安全隧道**:
  - **🔒 mTLS 加密**: 所有隧道流量均通过 mTLS 协议进行端到端加密，确保数据传输安全。
  - **🌍 全球组网**: 轻松构建跨区域、跨服务商的分布式转发网络。
- **直观的 Web UI**:
  - **📊 实时监控**: 在仪表盘上实时查看所有节点的 CPU、内存、网络状态和流量图表。
  - **🕹️ 便捷管理**: 通过现代化的 Web 界面，轻松管理所有用户、服务器节点和转发规则。
  - **🔗 连接诊断**: 一键测试规则的延迟与连通性，帮助您快速定位网络问题。
- **灵活部署**:
  - **🐳 Docker 一键部署**: 提供完整的 `docker-compose` 配置，数分钟内即可启动整个平台。
  - **💾 多数据库支持**: 兼容 **SQLite** 和 **MySQL**，从轻量级个人项目到企业级应用都能轻松应对。

## 🛠️ 技术栈

| 类别     | 技术                                       | 描述                                     |
| :------- | :----------------------------------------- | :--------------------------------------- |
| **前端** | `TypeScript`, `React`, `Vite`, `Ant Design`  | 提供类型安全、现代化的、响应迅速的用户界面。 |
| **后端** | `Go`, `Gin`, `GORM`                         | 确保高性能、高并发的核心服务。           |
| **Agent**  | `Go`                                       | 轻量级、高性能的客户端，资源占用极低。     |
| **通信** | `gRPC (Protobuf)`                          | 用于后端与 Agent 之间高效、可靠的通信。    |
| **部署** | `Docker`, `Docker Compose`                 | 实现快速、一致、跨平台的部署体验。         |

## 🚀 快速开始

我们推荐使用 Docker Compose 进行一键部署，这是最简单、最快捷的方式。

### 准备工作

1.  一台拥有公网 IP 的 Linux 服务器 (推荐 Ubuntu 20.04+ 或 CentOS 7+)。
2.  一个域名，并将其 A 记录指向您的服务器 IP。
3.  服务器上已安装 `Docker` 和 `Docker Compose`。
4.  服务器上已安装 `git`。

### 部署步骤

1.  **克隆仓库**:
    ```bash
    git clone https://github.com/yourusername/HermesPanel.git
    cd HermesPanel
    ```

2.  **配置 `.env` 文件**:
    根据 `.env.example` 文件创建一个 `.env` 文件，并填写您的域名、数据库密码和安全密钥。
    ```bash
    cp .env.example .env
    nano .env
    ```

3.  **启动服务**:
    ```bash
    docker-compose up -d --build
    ```
    等待几分钟，所有服务将会自动构建并启动。

4.  **访问面板**:
    在浏览器中访问 `https://您的域名`，即可看到 HermesPanel 的登录界面。

更详细的安装和配置指南，请参阅我们的 [**Wiki 文档**](https://github.com/yourusername/HermesPanel/wiki)。

## 🤝 贡献

我们欢迎任何形式的贡献！无论是提交 Issue、修复 Bug、增加新功能还是完善文档，都对项目非常有帮助。

请阅读我们的 [**贡献指南**](./CONTRIBUTING.md) 来开始您的贡献之旅。

## 📄 开源许可证

本项目基于 [MIT License](./LICENSE) 开源。
