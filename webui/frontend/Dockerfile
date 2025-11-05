# Build stage
FROM node:20-alpine AS builder

WORKDIR /app

# Configure npm to use Chinese mirror (default, not fallback)
RUN npm config set registry https://registry.npmmirror.com

# Copy package files
COPY package.json ./
RUN npm install

# Copy source files
COPY . .

# Build for production
RUN npm run build

# Production stage
FROM nginx:alpine

# Copy built files from builder
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

