/* ════════════════════════════════════════════════════════════════════════
 * KataClimb · Service Worker registrazione frontend
 * v3.56b — incluso da portale.html, agenda.html
 *
 * COSA FA
 *   1. Registra /sw.js al primo load
 *   2. Detecta aggiornamenti del SW (deploy nuovo)
 *   3. Quando nuovo SW pronto, manda 'SKIP_WAITING' (attivazione immediata)
 *   4. Ricarica la pagina quando il nuovo SW prende controllo
 *
 * COSA NON FA
 *   - Nessun blocco UI, niente prompt invasivi
 *   - Niente console.log rumorosi (solo warn/error)
 *
 * NOTE
 *   - In dev con localhost: il SW si registra comunque (per testing)
 *   - Se navigator.serviceWorker non esiste (es. iOS in InPrivate): silent fail
 * ════════════════════════════════════════════════════════════════════════ */

(function () {
  if (!('serviceWorker' in navigator)) return;

  // Aspetta load per non bloccare il rendering iniziale
  window.addEventListener('load', async () => {
    try {
      const reg = await navigator.serviceWorker.register('/sw.js', { scope: '/' });

      // Quando viene trovato un SW nuovo (deploy fresco)
      reg.addEventListener('updatefound', () => {
        const newSW = reg.installing;
        if (!newSW) return;
        newSW.addEventListener('statechange', () => {
          if (newSW.state === 'installed' && navigator.serviceWorker.controller) {
            // Nuova versione disponibile, ne forziamo l'attivazione
            newSW.postMessage({ type: 'SKIP_WAITING' });
          }
        });
      });

      // Quando il nuovo SW prende controllo, ricarica per usare codice fresh
      let refreshing = false;
      navigator.serviceWorker.addEventListener('controllerchange', () => {
        if (refreshing) return;
        refreshing = true;
        window.location.reload();
      });
    } catch (e) {
      console.warn('[sw-register]', e);
    }
  });
})();
