#!/bin/sh
# CD par tirage : le serveur va chercher sa mise à jour avec SA propre clé GitHub.
# Aucune clé, aucun secret déposé chez GitHub ; aucun accès entrant supplémentaire ici.
# Appelé par le timer systemd utilisateur paygo-cd.timer (voir script/systemd/).
set -eu
cd "$(dirname "$0")/.."
REPO=4n0nn43x/paygo

git fetch -q origin master
LOCAL=$(git rev-parse HEAD 2>/dev/null || echo none)
REMOTE=$(git rev-parse origin/master)
[ "$LOCAL" = "$REMOTE" ] && exit 0
echo "nouveau commit: $REMOTE"

# On ne déploie QUE si la CI est verte pour ce commit précis : c'est la même barrière que
# le job `deploy` de GitHub Actions, appliquée ici. Un commit rouge ne part jamais en prod.
CI=$(curl -sf "https://api.github.com/repos/$REPO/commits/$REMOTE/check-runs" \
     | python3 -c "
import json,sys
runs=json.load(sys.stdin).get('check_runs',[])
if not runs: print('attente')
elif any(r['status']!='completed' for r in runs): print('encours')
elif all(r['conclusion']=='success' for r in runs): print('verte')
else: print('rouge')" 2>/dev/null || echo injoignable)

case "$CI" in
  verte) ;;
  attente|encours) echo "CI pas terminée — on repasse au prochain tick"; exit 0 ;;
  rouge)  echo "CI ROUGE pour $REMOTE — déploiement refusé"; exit 1 ;;
  *)      echo "statut CI injoignable — refus par prudence"; exit 1 ;;
esac

# .env est gitignoré et l'état du worker vit dans un volume Docker : reset ne les touche pas.
git reset --hard "$REMOTE"
[ -f compose.yaml ] || { echo "compose.yaml absent de ce commit — abandon"; exit 1; }
docker compose up -d --build
docker image prune -f
echo "deploye: $REMOTE"
