FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY public ./public
USER node
ENV NODE_ENV=production PORT=8787
CMD ["node", "public/server.mjs"]
