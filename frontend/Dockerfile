# Local-dev runtime. Source is bind-mounted at runtime via docker-compose;
# only deps live in the image.
FROM node:22-alpine

WORKDIR /app

COPY package.json ./
RUN npm install

CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
