# syntax=docker/dockerfile:1
# Bases pinnées par digest : un tag est mutable, un digest ne l'est pas.
ARG NODE=node@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

# ---------- 1. build du front (Vite -> web/dist) ----------
FROM ${NODE} AS web
WORKDIR /app/web/app
COPY web/app/package.json web/app/package-lock.json ./
RUN npm ci --no-audit --fund=false
COPY web/app/ ./
RUN npm run build

# ---------- 2. dépendances de production du worker ----------
FROM ${NODE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# --omit=dev écarte forge-std (dépendance git, inutile au runtime) ; tsx est ajouté
# explicitement et pinné parce qu'il exécute le worker en TypeScript.
RUN npm ci --omit=dev --no-audit --fund=false && npm i --no-save --no-audit tsx@4.22.4

# ---------- 3. image finale ----------
FROM ${NODE} AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=web  /app/web/dist     ./web/dist
COPY package.json tsconfig.json ./
COPY worker/ ./worker/
# npm n'est jamais appelé au runtime (le CMD lance tsx directement) et son node_modules
# interne porte 11 CVE HIGH/CRITICAL corrigeables. On le supprime : surface en moins,
# et le scan de l'image devient propre au lieu d'être noyé sous du bruit inatteignable.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/lib/node_modules/corepack /usr/local/bin/corepack

# Le volume d'état hérite des permissions de ce répertoire à sa création : sans ce
# chown, un volume neuf appartient à root et le worker (uid 1000) ne peut pas écrire.
RUN mkdir -p /data && chown node:node /data
# `node` (uid 1000) existe déjà dans l'image officielle : pas de root au runtime.
USER node
EXPOSE 8787
CMD ["node_modules/.bin/tsx", "worker/settle.ts"]
