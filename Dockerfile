##################################################################################
# Frontend builder stage
FROM --platform=$BUILDPLATFORM node:20-alpine AS plik-frontend-builder

# Install needed binaries
RUN apk add --no-cache git make bash

# Add the source code
COPY Makefile .
COPY webapp /webapp

# Build frontend assets
RUN make clean-frontend frontend

##################################################################################
# Backend builder stage  
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

# Build the application
RUN releaser/releaser.sh

##################################################################################
# Final runtime image
FROM alpine:3.18

# Install ca-certificates
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

# Copy built application
COPY --from=plik-builder --chown=1000:1000 /go/src/github.com/root-gg/plik/release /home/plik/

# Create a startup script that sets proper MIME types
COPY <<EOF /home/plik/fix-mime.sh
#!/bin/sh

# Function to set proper MIME types for mounted files
fix_webapp_permissions() {
    if [ -d "/home/plik/webapp/dist" ]; then
        echo "Setting proper permissions and MIME type associations for webapp files..."
        find /home/plik/webapp/dist -name "*.css" -exec file {} \; | head -5
        find /home/plik/webapp/dist -name "*.js" -exec file {} \; | head -5
        
        # Ensure files are readable
        chmod -R 755 /home/plik/webapp/dist 2>/dev/null || true
        
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
    fi
}

# Set environment variable for MIME types
export PLIK_MIME_TYPES_FILE="/home/plik/mime.types"

# Fix permissions and MIME types
fix_webapp_permissions

# Start the plik server
cd /home/plik/server
exec ./plikd
EOF

RUN chmod +x /home/plik/fix-mime.sh && chown plik:plik /home/plik/fix-mime.sh

# Create webapp directory structure for bind mounting
RUN mkdir -p /home/plik/webapp/dist && chown -R plik:plik /home/plik/webapp

EXPOSE 8080
USER plik
WORKDIR /home/plik
CMD ["/home/plik/fix-mime.sh"]
