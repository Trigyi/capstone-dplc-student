# Architecture Mission 2 — World Cup 2026 sur Kubernetes

## Schéma d'architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  VPS Ikoula — 178.170.25.135 (Debian 13, 2 Go RAM) │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  k3s (Kubernetes single-node)                │  │
│  │                                              │  │
│  │  ┌────────────┐   Ingress (Traefik)          │  │
│  │  │  :80 HTTP  │──────────────┐               │  │
│  │  └────────────┘              │               │  │
│  │                              ▼               │  │
│  │  namespace: default          │               │  │
│  │  ┌──────────────────────┐    │               │  │
│  │  │  worldcup2026-app    │◄───┘               │  │
│  │  │  (Deployment x2-4)   │                    │  │
│  │  │  Node.js :3000       │                    │  │
│  │  │  + /metrics Prom.    │                    │  │
│  │  └──────────┬───────────┘                    │  │
│  │             │ ClusterIP                      │  │
│  │             ▼                                │  │
│  │  ┌──────────────────────┐                    │  │
│  │  │  worldcup2026-postgres│                   │  │
│  │  │  (StatefulSet x1)    │                    │  │
│  │  │  PostgreSQL 15 :5432 │                    │  │
│  │  │  PVC 1Gi             │                    │  │
│  │  └──────────────────────┘                    │  │
│  │                                              │  │
│  │  namespace: monitoring                       │  │
│  │  ┌────────────┐  ┌────────┐  ┌───────────┐  │  │
│  │  │ Prometheus │  │ Loki   │  │  Grafana  │◄─┼──┤ grafana.*.sslip.io
│  │  │ scrape /15s│  │+ Promt.│  │  :80      │  │  │
│  │  └────────────┘  └────────┘  └───────────┘  │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Composants et justifications

| Composant | Choix | Justification |
|-----------|-------|---------------|
| Orchestrateur | k3s | Kubernetes allégé adapté à un VPS 2 Go RAM ; footprint ~512 Mo vs ~1.5 Go pour k8s complet |
| Ingress | Traefik (intégré k3s) | Inclus dans k3s, zéro configuration supplémentaire, gère HTTP/HTTPS |
| Registry | Docker Hub (public) | Gratuit, accessible depuis le VPS sans authentification supplémentaire |
| DNS public | sslip.io | Résolution DNS magique basée sur l'IP, aucun domaine à acheter |
| Base de données | PostgreSQL 15 (in-cluster) | Simple à déployer pour un capstone ; en production, on préférerait un PaaS managé (RDS, Cloud SQL) |
| Observabilité | Prometheus + Grafana + Loki | Stack standard open-source ; kube-prometheus-stack écarté (trop lourd pour 2 Go RAM) |
| Secrets | Helm `randAlphaNum` + `lookup` | Génération aléatoire à l'install, préservée aux upgrades — aucun credential en clair dans Git |

## Trade-offs identifiés

### Choix retenus vs alternatives

**k3s sur VPS single-node vs GKE/EKS managé**
- ✅ Coût quasi nul (VPS ~5€/mois vs GKE ~50-150€/mois pour un cluster managé)
- ✅ Contrôle total
- ❌ Pas de haute disponibilité du plan de contrôle (single node = SPOF)
- ❌ Gestion manuelle des mises à jour k3s

**PostgreSQL in-cluster vs RDS/Cloud SQL**
- ✅ Coût zéro
- ❌ Pas de backups automatiques, pas de failover
- En production : migrer vers un PaaS managé avec réplication

**Prometheus standalone vs kube-prometheus-stack**
- ✅ ~150 Mo RAM vs ~700 Mo pour la stack complète
- ❌ Pas de node-exporter, pas de kube-state-metrics
- Trade-off assumé : contrainte RAM VPS 2 Go

**Image pullPolicy: IfNotPresent vs Always**
- ✅ Redémarrage de pod en ~7s (image déjà cachée sur le nœud)
- ❌ Nécessite un changement de tag (`v1.1`, `v1.2`…) pour forcer le pull d'une nouvelle image
- Décision : utiliser des tags versionnés, jamais `latest` en production

## Estimation de coût

### Infrastructure actuelle

| Ressource | Fournisseur | Coût mensuel |
|-----------|-------------|--------------|
| VPS 1 vCPU / 2 Go RAM / 20 Go SSD | Ikoula (code YNOV2026) | **0 € (gratuit capstone)** |
| Docker Hub (images publiques) | Docker Inc. | 0 € |
| Domaine DNS | sslip.io | 0 € |
| **Total capstone** | | **0 €/mois** |

### Coût équivalent sans code promo

| Ressource | Fournisseur | Coût mensuel estimé |
|-----------|-------------|---------------------|
| VPS 1 vCPU / 2 Go RAM | Ikoula | ~5-8 € HT |
| Docker Hub (plan gratuit) | Docker Inc. | 0 € |
| **Total production minimale** | | **~5-8 €/mois HT** |

### Comparaison avec cloud public (même workload)

| Scénario | AWS | GCP | Azure |
|----------|-----|-----|-------|
| EKS/GKE/AKS managé (cluster fee) | +73 $/mois | +73 $/mois | +73 $/mois |
| 2 nœuds t3.small / e2-small / B2s | ~34 $/mois | ~28 $/mois | ~30 $/mois |
| RDS PostgreSQL db.t3.micro | ~15 $/mois | ~10 $/mois | ~15 $/mois |
| **Total cloud managé** | **~122 $/mois** | **~111 $/mois** | **~118 $/mois** |

**Économie réalisée : ~110 €/mois** en choisissant un VPS + k3s plutôt qu'un cluster managé cloud.

### Projection à l'échelle (autoscaling max)

| Événement | Replicas | RAM app supplémentaire | Impact coût |
|-----------|----------|------------------------|-------------|
| Trafic normal | 2 | 128 Mo × 2 = 256 Mo | ~5 €/mois (VPS actuel) |
| Pic CPU → HPA max | 4 | 128 Mo × 4 = 512 Mo | ~5 €/mois (tient dans 2 Go) |
| Au-delà (> 4 replicas) | N/A | Dépasserait 2 Go RAM | Upgrade VPS ~10 €/mois |

## Configuration Kubernetes résumée

```yaml
# Résilience
terminationGracePeriodSeconds: 10   # borne le shutdown à 10s
livenessProbe:  /api/health          # route légère, jamais bloquée
readinessProbe: /api/health/db       # vérifie la connexion PostgreSQL

# Autoscaling
HPA: min=2 / max=4 / targetCPU=70%

# Ressources par pod app
requests: cpu=50m  memory=64Mi
limits:   cpu=250m memory=128Mi

# Sécurité
DB_PASSWORD: Secret K8s généré (randAlphaNum 24 chars)
pullPolicy: IfNotPresent (image taguée v1.x, pas latest)
```

## (Bonus) CronJob — Rapport automatique de classement

### Concept

Un CronJob Kubernetes qui s'exécute toutes les heures, interroge PostgreSQL et génère
un rapport de classement par groupe dans les logs (consultables via Loki/Grafana).

### Design

```
CronJob (toutes les heures)
    └── Job → Pod éphémère Node.js
                  └── SELECT classement depuis PostgreSQL
                  └── Calcul points / diff. buts / buts marqués
                  └── Affichage rapport dans stdout
                  └── Pod se termine (exit 0)
```

### Justification des choix

| Choix | Justification |
|-------|--------------|
| CronJob plutôt que script cron Linux | Natif Kubernetes, observable via `kubectl get jobs`, logs centralisés dans Loki |
| Pod éphémère (pas un Deployment) | Le job fait une tâche ponctuelle et se termine — pas besoin de garder un process en vie |
| Accès DB via Secret existant | Réutilise `worldcup2026-postgres-secret` déjà créé par le Helm chart — pas de nouveau credential |
| `restartPolicy: OnFailure` | Kubernetes relance automatiquement si le pod échoue (ex: DB pas encore prête) |
| Image légère `node:18-alpine` | Minimise le temps de pull et l'empreinte mémoire du job éphémère |

### Manifest prévu

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: worldcup2026-standings-report
spec:
  schedule: "0 * * * *"   # toutes les heures
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: standings-reporter
              image: trigyi/worldcup2026-app:v1.1
              command: ["node", "jobs/standings-report.js"]
              env:
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: worldcup2026-postgres-secret
                      key: POSTGRES_PASSWORD
```

### Limites identifiées

- **Non implémenté** par manque de temps — priorisé après résilience, autoscaling et observabilité
- Le script `jobs/standings-report.js` serait à ajouter dans l'image Docker (rebuild + push v1.2)
- En production, le rapport serait poussé vers un webhook Slack ou stocké en base plutôt que dans stdout

## Résultats des tests

| Test | Résultat | Critère |
|------|----------|---------|
| Résilience (kill pod) | **7.47s** downtime | ✅ < 15s |
| Autoscaling sous charge | 2 → 4 replicas en ~2min | ✅ HPA fonctionnel |
| Accès public | http://worldcup.178.170.25.135.sslip.io | ✅ |
| Métriques Prometheus | `http_requests_total`, `http_request_duration_seconds` | ✅ |
| Logs centralisés | Loki + Promtail, tous namespaces | ✅ |
| Alerting | 2 règles actives (latence P95, HA instances) | ✅ |
