FROM public.ecr.aws/docker/library/node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --quiet
COPY src/ ./src/
RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -s /bin/sh -D appuser
RUN chown -R appuser:appgroup /app
USER appuser
EXPOSE 3002
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3002/health || exit 1
CMD ["node", "src/app.js"]
