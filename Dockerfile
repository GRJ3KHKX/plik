##################################################################################
FROM --platform=$BUILDPLATFORM node:20-alpine AS plik-frontend-builder

# Install needed binaries
RUN apk add --no-cache git make bash

# Add the source code
COPY Makefile .
COPY webapp /webapp

RUN make clean-frontend frontend

##################################################################################
FROM --platform=$BUILDPLATFORM golang:1-bullseye AS plik-builder

# Install needed binaries
RUN apt-get update && apt-get install -y build-essential crossbuild-essential-armhf crossbuild-essential-armel crossbuild-essential-arm64 crossbuild-essential-i386

# Prepare the source location
RUN mkdir -p /go/src/github.com/root-gg/plik
WORKDIR /go/src/github.com/root-gg/plik

# Copy webapp build from previous stage
COPY --from=plik-frontend-builder /webapp/dist webapp/dist

ARG CLIENT_TARGETS=""
ENV CLIENT_TARGETS=$CLIENT_TARGETS

ARG TARGETOS TARGETARCH TARGETVARIANT CC
ENV TARGETOS=$TARGETOS
ENV TARGETARCH=$TARGETARCH
ENV TARGETVARIANT=$TARGETVARIANT
ENV CC=$CC

# Add the source code
COPY . .

# Build manually without any git dependencies
RUN echo "Building Plik server manually without git..." && \
    cd server && \
    echo 'package common; const buildInfoString = "docker-build"' > common/build_info.go && \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux go build \
        -ldflags="-X github.com/root-gg/plik/server/common.buildInfoString=docker-build -w -s -extldflags=-static" \
        -tags "osusergo,netgo,sqlite_omit_load_extension" \
        -o plikd . && \
    cd .. && \
    mkdir -p release/server && \
    mkdir -p release/webapp && \
    cp server/plikd release/server/ && \
    cp server/plikd.cfg release/server/ && \
    cp -r webapp/dist release/webapp/ && \
    chmod +x release/server/plikd

##################################################################################
FROM alpine:3.18 AS plik-image

RUN apk add --no-cache ca-certificates

# Create plik user
ENV USER=plik
ENV UID=1000

RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/home/plik" \
    --shell "/bin/false" \
    --uid "${UID}" \
    "${USER}"

COPY --from=plik-builder --chown=1000:1000 /go/src/github.com/root-gg/plik/release /home/plik/

# Create startup script that handles MIME types for bind mounts
RUN cat > /home/plik/start-with-mime-fix.sh << 'EOF'
#!/bin/sh

# Function to set proper MIME types for mounted files
fix_webapp_permissions() {
    if [ -d "/home/plik/webapp/dist" ]; then
        echo "Setting proper permissions and checking MIME types for webapp files..."
        
        # Ensure files are readable
        chmod -R 755 /home/plik/webapp/dist 2>/dev/null || true
        
        # Check file types (for debugging)
        if [ -f "/home/plik/webapp/dist/css/app.css" ]; then
            echo "CSS file type: $(file /home/plik/webapp/dist/css/app.css)"
        fi
        if [ -f "/home/plik/webapp/dist/js/app.js" ]; then
            echo "JS file type: $(file /home/plik/webapp/dist/js/app.js)"
        fi
        
        # Create/update mime.types if needed
        if [ ! -f "/home/plik/mime.types" ]; then
            cat > /home/plik/mime.types << 'MIME'
text/css                        css
application/javascript          js
text/javascript                 js
image/jpeg                      jpeg jpg
image/png                       png
image/gif                       gif
image/svg+xml                   svg svgz
application/json                json
text/html                       html htm
text/plain                      txt
font/woff                       woff
font/woff2                      woff2
application/font-woff           woff
application/font-woff2          woff2
MIME
        fi
        
        echo "MIME types configuration created at /home/plik/mime.types"
    fi
}

# Set environment variable for MIME types
export PLIK_MIME_TYPES_FILE="/home/plik/mime.types"

# Fix permissions and MIME types
fix_webapp_permissions

echo "Starting Plik server with MIME type fixes..."

# Start the plik server
cd /home/plik/server
exec ./plikd
EOF

RUN chmod +x /home/plik/start-with-mime-fix.sh && chown plik:plik /home/plik/start-with-mime-fix.sh

# Create directories for bind mounts  
RUN mkdir -p /home/plik/webapp/dist && chown -R plik:plik /home/plik/webapp

EXPOSE 8080
USER plik
WORKDIR /home/plik
CMD ["/home/plik/start-with-mime-fix.sh"]
