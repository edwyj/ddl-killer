FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
COPY scripts ./scripts
ENV PORT=3000
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "src/index.js"]
