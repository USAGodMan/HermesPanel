# --- Build Stage ---
# Use the official Golang image as a builder
FROM golang:1.24.5-alpine AS builder

# Set the working directory inside the container
WORKDIR /app

# Copy go.mod and go.sum to download dependencies first
# This leverages Docker's layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy all source code
COPY . .

# Build the agent application statically inside its directory
# CGO_ENABLED=0 is crucial for creating a static binary that runs in minimal base images like alpine
# -ldflags="-s -w" strips debug information, significantly reducing the binary size
RUN cd agent && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/hermes-agent .

# --- Final Stage ---
# Use a minimal base image for the final container
FROM alpine:latest

# Create the directory for the config file
RUN mkdir -p /etc/hermes

# Copy the compiled binary from the builder stage
COPY --from=builder /app/hermes-agent /usr/local/bin/hermes-agent

# Note: The agent expects a config file. In docker-compose, you should mount a volume to /etc/hermes/config.json
# For standalone runs, you can build with a config file or provide it at runtime.
# Example: COPY ./agent/config.json /etc/hermes/config.json

# Set the entrypoint for the container to run the agent, explicitly providing the config path
ENTRYPOINT ["hermes-agent", "--config", "/etc/hermes/config.json"]
