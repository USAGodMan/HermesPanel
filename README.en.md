<p align="right">English | <a href="./README.md">中文 (Chinese)</a> | <a href="./README.ja.md">日本語 (Japanese)</a></p>
# HermesPanel - High-Performance Traffic Orchestration & Forwarding Dashboard
<p align="center">
  <strong>A modern, feature-rich traffic tunneling and port forwarding management panel, engineered for high availability, flexibility, and granular traffic control.</strong>
</p>

<p align="center">
  <a href="https://github.com/Hermes-Panel/hermes/releases"><img src="https://img.shields.io/github/v/release/Hermes-Panel/hermes.svg" alt="Latest Release"></a>
  <a href="#"><img src="https://img.shields.io/badge/Go-1.21%2B-blue.svg" alt="Go Version"></a>
  <a href="#"><img src="https://img.shields.io/badge/React-18%2B-blue.svg" alt="React Version"></a>
  <a href="#"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

---

**HermesPanel** is more than just a port forwarding tool. It's a powerful traffic orchestration platform that gives you complete control over your network flows. Whether you're implementing high availability for your services, conducting A/B tests, or enabling intelligent routing for a multi-region deployment, HermesPanel is built to handle it with ease.

## ✨ Core Features

- **Multi-Protocol Support**: Forwarding for **TCP** and **UDP** traffic, available in both direct and secure tunnel modes.
- **High Availability**:
  - **✅ Health Checks**: Automatically monitor the health of your backend services to get real-time availability status.
  - **✅ Automatic Failover**: Intelligently route traffic away from unhealthy endpoints, ensuring seamless service continuity.
- **Advanced Load Balancing**:
  - **🔀 Multiple Strategies**: Built-in support for **Random**, **Round Robin**, **Weighted Round Robin**, **Least Connections**, and **IP Hash** algorithms.
  - **⚖️ Weighted Targets**: Assign different weights to backend services for fine-grained, proportional traffic distribution.
- **Secure Tunneling**:
  - **🔒 mTLS Encryption**: All tunnel traffic is end-to-end encrypted using mutual TLS (mTLS) to guarantee data security.
  - **🌍 Global Networking**: Effortlessly build a distributed forwarding network across different regions and cloud providers.
- **Intuitive Web UI**:
  - **📊 Real-time Monitoring**: A comprehensive dashboard to monitor node status (CPU, memory, network), traffic statistics, and performance metrics in real-time.
  - **🕹️ Effortless Management**: A modern web interface to easily manage all users, server nodes, and forwarding rules.
  - **🔗 Diagnostic Tools**: One-click latency and connectivity testing for rules to quickly troubleshoot network issues.
- **Flexible Deployment**:
  - **🐳 One-Click Docker Deploy**: Comes with a complete `docker-compose` setup for launching the entire platform in minutes.
  - **💾 Multi-Database Support**: Compatible with both **SQLite** and **MySQL** to fit needs ranging from small personal projects to large-scale enterprise applications.

## 🛠️ Tech Stack

| Category      | Technologies                               | Description                                      |
| :------------ | :----------------------------------------- | :----------------------------------------------- |
| **Frontend**  | `TypeScript`, `React`, `Vite`, `Ant Design`  | A type-safe, modern, and responsive user interface. |
| **Backend**   | `Go`, `Gin`, `GORM`                         | A high-performance, concurrent core service.       |
| **Agent**     | `Go`                                       | A lightweight, high-performance client with a minimal footprint. |
| **Transport** | `gRPC (Protobuf)`                          | For efficient and reliable backend-agent communication. |
| **Deployment**| `Docker`, `Docker Compose`                 | For a fast, consistent, and cross-platform deployment experience. |

## 🚀 Quick Start

The recommended way to get started is by using Docker Compose for a one-click deployment.

### Prerequisites

1.  A Linux server with a public IP address (Ubuntu 20.04+ or CentOS 7+ recommended).
2.  A domain name with its A record pointing to your server's public IP.
3.  `Docker` and `Docker Compose` installed on your server.
4.  `git` installed on your server.

### Deployment Steps

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/yourusername/HermesPanel.git
    cd HermesPanel
    ```

2.  **Configure your environment**:
    Create a `.env` file from the example template and fill in your domain, database passwords, and security keys.
    ```bash
    cp .env.example .env
    nano .env
    ```

3.  **Launch the services**:
    ```bash
    docker-compose up -d --build
    ```
    Wait a few minutes for the services to be built and started.

4.  **Access the panel**:
    Open your web browser and navigate to `https://your-domain.com` to see the HermesPanel login page.

For more detailed installation and configuration instructions, please refer to our [**Wiki**](https://github.com/Hermes-Panel/HermesPanel/wiki).

## 🤝 Contributing

Contributions of all kinds are welcome! Whether it's submitting an issue, fixing a bug, adding a new feature, or improving the documentation, your help is greatly appreciated.

Please read our [**Contributing Guidelines**](./CONTRIBUTING.md) to get started.

## 📄 License

This project is licensed under the [MIT License](./LICENSE).
