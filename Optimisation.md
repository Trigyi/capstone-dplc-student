# Optimisation du Dockerfile

## Dockerfile initial

```dockerfile
FROM node:latest

WORKDIR /app

COPY . .

RUN npm install

EXPOSE 3000

CMD ["node", "main.js"]
```

## Anti-patterns identifiés

1. **`FROM node:latest`** — tag flottant : la base change à chaque rebuild (build non
   reproductible) et `node:latest` est une image Debian complète, beaucoup plus lourde
   que nécessaire.
2. **`COPY . .` avant `RUN npm install`** — invalide le cache Docker des dépendances à
   chaque modification de code source (`main.js`, `public/`...), alors que les
   dépendances n'ont pas changé. En l'absence de `.dockerignore`, ça copie aussi les
   tests, le `.git`, etc. dans l'image.
3. **`RUN npm install`** — installe les `devDependencies` (jest, supertest, fast-check)
   dans l'image de production, et n'est pas reproductible (pas de garantie de respecter
   strictement `package-lock.json`).
4. **Pas de multi-stage build** — l'image finale contient les outils nécessaires à
   l'installation des paquets en plus du code applicatif : tout est mélangé dans une
   seule couche, rien n'est éliminé du résultat final.
5. **Pas d'utilisateur non-root (`USER`)** — le process tourne en `root` dans le
   conteneur, ce qui élargit la surface d'attaque en cas de compromission de
   l'application.
6. **Absence de `.dockerignore`** — aggrave les points 2 et 4 en faisant remonter des
   fichiers inutiles (et potentiellement sensibles) dans le contexte de build.

## Corrections apportées

### `app/Dockerfile`

```dockerfile
FROM node:20-slim AS deps

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci --omit=dev


FROM node:20-slim

ENV NODE_ENV=production

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY main.js init.sql ./
COPY public ./public

RUN useradd --uid 1001 --create-home appuser \
  && chown -R appuser:appuser /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/api/health/db', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "main.js"]
```

| Correction | Anti-pattern résolu | Pourquoi |
|---|---|---|
| `node:20-slim` au lieu de `node:latest` | #1 | Version Node figée (reproductible) et base Debian minimale (moins de paquets, moins de surface d'attaque) |
| Copie de `package.json`/`package-lock.json` seuls avant l'install | #2 | Le layer `npm ci` reste en cache tant que les dépendances ne changent pas ; seul un rebuild du code source est nécessaire ensuite |
| `npm ci --omit=dev` | #3 | Installation strictement basée sur le lockfile (reproductible) et sans les dépendances de développement |
| Multi-stage build (`deps` → image finale) | #4 | Seuls `node_modules` (prod), le code applicatif et `public/` sont copiés dans l'image finale ; le stage `deps` (cache npm, etc.) est jeté |
| `USER appuser` (uid 1001) | #5 | Le conteneur ne tourne plus en root |
| Ajout de `app/.dockerignore` | #6 | Exclut `node_modules`, `tests/`, `.git`, `*.md`, `.env` du contexte de build |
| `HEALTHCHECK` | bonus | Permet à Docker/Compose/Kubernetes de détecter un conteneur qui répond mais ne sert plus de trafic correctement (utile pour la résilience demandée en Mission 2) |

### `app/.dockerignore` (nouveau)

```
node_modules
npm-debug.log
.git
.gitignore
tests
jest.config.js
*.md
.env
```

### `app/package-lock.json`

Le lockfile fourni n'était plus synchronisé avec `package.json` (dépendances optionnelles
manquantes : `@emnapi/core`, `@emnapi/runtime`), ce qui faisait échouer `npm ci`. Il a été
régénéré avec `npm install --package-lock-only` pour que l'installation reproductible
fonctionne en CI/CD comme en local.

## Résultats mesurés

| | Avant | Après |
|---|---|---|
| Taille de l'image | 1.89 GB | 317 MB |
| Réduction | — | ~83% |
| Utilisateur dans le conteneur | `root` | `appuser` (uid 1001) |
| Healthcheck | absent | présent (`/api/health/db`) |

Vérifié avec `docker-compose up --build` : l'app répond `200` sur `/`, `/api/health/db`
renvoie `{"status":"ok"}`, et `docker inspect` confirme l'état `healthy`.
