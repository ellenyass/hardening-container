# Node.js 22 LTS em Alpine, com tag e digest fixos.
# A variante Alpine evita o sistema completo do ubuntu:latest e não instala
# compiladores, git ou o gerenciador de pacotes da distribuição.
FROM node:22.23.4-alpine3.24@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914

ENV NODE_ENV=production

WORKDIR /app

# A aplicação não tem dependências. Entra na imagem só o arquivo executado.
COPY --chown=node:node app/server.js ./server.js

# A imagem oficial já inclui o usuário node. A aplicação não precisa de root.
USER node

EXPOSE 3000

CMD ["node", "server.js"]
