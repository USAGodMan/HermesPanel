# Contributing to HermesPanel

First off, thank you for considering contributing to HermesPanel! We welcome any form of contribution, from reporting a bug or suggesting a feature, to writing code or improving our documentation. Every contribution is valuable to us.

This document provides a set of guidelines to help you contribute to the project smoothly.

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](./CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior.

*(Note: You will need to create a `CODE_OF_CONDUCT.md` file. You can easily generate one from a standard template, like the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)).*

## How Can I Contribute?

There are many ways to contribute to HermesPanel:

*   **Reporting Bugs**: If you find a bug, please open an issue and provide detailed steps to reproduce it.
*   **Suggesting Enhancements**: Have an idea for a new feature or an improvement to an existing one? Feel free to open an issue to discuss it.
*   **Pull Requests**: If you're ready to contribute code, we'd love to review your pull request.
*   **Improving Documentation**: Found a typo or an unclear section in our README or Wiki? Let us know or submit a PR!
*   **Translating**: Help us make HermesPanel accessible to more people by translating the UI or documentation.

## Your First Contribution

Unsure where to begin? A great place to start is by looking for issues tagged with `good first issue` or `help wanted`. These are typically smaller, well-defined tasks that are perfect for getting familiar with the codebase.

## Development Setup

To get started with development, you'll need to set up the project on your local machine.

### Prerequisites

*   Go (version 1.21 or later)
*   Node.js (version 20 or later) and npm
*   Docker and Docker Compose
*   `protoc` compiler for gRPC

### Setup Steps

1.  **Fork the repository** on GitHub.
2.  **Clone your fork** to your local machine:
    ```bash
    git clone https://github.com/YOUR_USERNAME/HermesPanel.git
    cd HermesPanel
    ```
3.  **Set up the upstream remote**:
    ```bash
    git remote add upstream https://github.com/Hermes-Panel/HermesPanel.git
    ```
4.  **Install dependencies**:
    *   **Backend & Agent**:
        ```bash
        cd backend && go mod tidy
        cd ../agent && go mod tidy
        ```
    *   **Frontend**:
        ```bash
        cd frontend && npm install
        ```
5.  **Run the project using Docker Compose**:
    We recommend using Docker Compose for a consistent development environment. Create a `.env` file from the example and start the services:
    ```bash
    cp .env.example .env
    # Edit the .env file with your development settings
    docker-compose up --build
    ```

## Submitting a Pull Request (PR)

When you're ready to submit your changes, please follow these steps:

1.  **Create a new branch** for your feature or bugfix:
    ```bash
    git checkout -b feature/my-awesome-feature
    ```
2.  **Make your changes**. Write clean, readable, and well-commented code.
    *   **Backend/Agent**: Follow Go's standard formatting (`gofmt`).
    *   **Frontend**: Follow the project's existing code style, enforced by ESLint and Prettier.
3.  **Commit your changes** with a clear and descriptive commit message. We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.
    *   Example: `feat: Add IP Hash load balancing strategy`
    *   Example: `fix: Correctly parse remote addresses in rule list`
4.  **Push your branch** to your fork on GitHub:
    ```bash
    git push origin feature/my-awesome-feature
    ```
5.  **Open a Pull Request** from your branch to the `main` branch of the `Hermes-Panel/HermesPanel` repository.
6.  **Fill out the PR template**. Provide a clear title and a detailed description of your changes. If your PR addresses an existing issue, be sure to link it (e.g., `Closes #123`).
7.  **Wait for a review**. A project maintainer will review your code, provide feedback, and merge it once it's ready.

## Style Guides

### Git Commit Messages

*   Use the present tense ("Add feature" not "Added feature").
*   Use the imperative mood ("Move cursor to..." not "Moves cursor to...").
*   Limit the first line to 72 characters or less.
*   Reference issues and PRs liberally in the body.

### Go Style

*   We follow the standard Go formatting enforced by `gofmt` and `goimports`. Please run these tools before committing your changes.

### TypeScript/React Style

*   We use ESLint and Prettier to maintain a consistent code style. Please run `npm run lint` and `npm run format` in the `frontend` directory before committing.

Thank you again for your interest in making HermesPanel better! We look forward to your contributions.
