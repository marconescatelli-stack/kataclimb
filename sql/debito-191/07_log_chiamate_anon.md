# DEBITO-191 · 07 — La falla è mai stata usata?

Le query per i log di Supabase, e il risultato del 22 settembre 2026.

**Attenzione a dove si eseguono.** Sono ClickHouse, non PostgreSQL. Vanno nei *Logs* di Supabase,
non nel SQL Editor. Sono di sola lettura.

## Il limite, prima dei numeri

I log di questo progetto tengono **24 ore**. La finestra disponibile il 22 settembre andava dal
**21 settembre alle 17:00** al **22 settembre alle 16:56** (UTC). L'interfaccia stessa non lascia
chiedere una finestra più larga di 24 ore.

Quindi quello che segue dice che **in quelle 24 ore nessuno ha sfruttato la falla**. Non dice
niente su prima. Le funzioni sono aperte da quando sono nate, e la più vecchia ha mesi. Se serve
sapere cosa è successo nei mesi scorsi, i log non ce l'hanno: andrebbero attivati i log a lunga
conservazione, che è una decisione a parte.

## Come si distingue una chiamata anonima

Nei log di frontiera ogni richiesta porta due JWT distinti:

- `request.sb.jwt.apikey.payload.role` è il ruolo della chiave usata come `apikey`;
- `request.sb.jwt.authorization.payload.role` è il ruolo del token in `Authorization`.

Quando un utente è loggato, il secondo dice `authenticated`. Quando la pagina chiama senza
sessione, entrambi dicono `anon`. Il ruolo effettivo è il secondo, e se manca vale il primo.

Le richieste `OPTIONS` vanno escluse sempre: sono i preflight CORS, che per costruzione non
portano l'header `Authorization` e risultano senza ruolo. Contarle come anonime è l'errore facile.

## Query 1 · le quattro funzioni più esposte

```sql
SELECT
  replaceRegexpOne(log_attributes['request.path'], '^.*/rest/v1/rpc/', '') AS funzione,
  coalesce(nullIf(log_attributes['request.sb.jwt.authorization.payload.role'], ''),
           nullIf(log_attributes['request.sb.jwt.apikey.payload.role'], ''),
           '(nessun jwt)')                                     AS ruolo_effettivo,
  log_attributes['request.method']                             AS metodo,
  count(*)                                                     AS chiamate,
  uniqExact(log_attributes['request.headers.cf_connecting_ip']) AS ip_distinti,
  groupUniqArray(log_attributes['request.headers.cf_connecting_ip']) AS ip,
  groupUniqArray(substring(log_attributes['request.headers.user_agent'], 1, 60)) AS user_agent,
  groupUniqArray(log_attributes['request.cf.country'])         AS paesi,
  countIf(log_attributes['response.status_code'] = '200')      AS risposte_200,
  min(timestamp) AS prima, max(timestamp) AS ultima
FROM logs
WHERE source = 'edge_logs'
  AND position(log_attributes['request.path'], '/rest/v1/rpc/') > 0
  AND funzione IN ('get_leads_da_contattare','get_famiglia',
                   'get_consensi_minore','get_timeline_persona')
GROUP BY funzione, ruolo_effettivo, metodo
ORDER BY chiamate DESC;
```

### Risultato, 21 set 17:00 → 22 set 16:56

| funzione | ruolo | metodo | chiamate | IP distinti | risposte 200 |
|---|---|---|---|---|---|
| get_leads_da_contattare | authenticated | POST | 7 | 3 | 5 |
| get_famiglia | authenticated | POST | 5 | 2 | 2 |
| get_leads_da_contattare | (nessun jwt) | OPTIONS | 3 | 3 | 3 |
| get_famiglia | (nessun jwt) | OPTIONS | 1 | 1 | 1 |
| get_consensi_minore | — | — | 0 | 0 | 0 |
| get_timeline_persona | — | — | 0 | 0 | 0 |

**Chiamate vere con ruolo `anon`: zero.** Le quattro senza JWT sono tutte `OPTIONS`, cioè i
preflight del browser, e le ho verificate una per una.

Le chiamate vere arrivano da due reti, Fastweb in Italia e Digi Spain in Spagna, tutte con
`referer https://kataclimb.com/`, da Windows, macOS e iPhone. Sono sessioni di staff.

Da notare, fuori tema ma visibile: **5 richieste su 12 hanno risposto 400**, tre su
`get_famiglia` e due su `get_leads_da_contattare`. Vale la pena guardare perché quelle chiamate
falliscono.

## Query 2 · tutte le RPC chiamate da anon

Più utile della prima, perché non presuppone quali funzioni guardare.

```sql
SELECT
  replaceRegexpOne(log_attributes['request.path'], '^.*/rest/v1/rpc/', '') AS funzione,
  count(*)                                                      AS chiamate_anon,
  uniqExact(log_attributes['request.headers.cf_connecting_ip'])  AS ip_distinti,
  groupUniqArray(log_attributes['request.cf.country'])           AS paesi,
  countIf(log_attributes['response.status_code'] = '200')        AS risposte_200
FROM logs
WHERE source = 'edge_logs'
  AND position(log_attributes['request.path'], '/rest/v1/rpc/') > 0
  AND log_attributes['request.method'] != 'OPTIONS'
  AND coalesce(nullIf(log_attributes['request.sb.jwt.authorization.payload.role'], ''),
               nullIf(log_attributes['request.sb.jwt.apikey.payload.role'], ''), '') = 'anon'
GROUP BY funzione
ORDER BY chiamate_anon DESC;
```

### Risultato, stessa finestra

| funzione | chiamate da anon | IP distinti | paesi | risposte 200 |
|---|---|---|---|---|
| get_eventi_calendario | 60 | 19 | IT, ES, US | 60 |
| conteggi_prima_lezione | 14 | 8 | IT, ES, US | 14 |

Sono le uniche due. Tutte e due sono in classe C, cioè pubbliche a ragione: la prima serve la
striscia eventi di `orari.html` e `eventi.html`, la seconda i conteggi degli slot delle landing.
Il traffico anonimo verso il database, in 24 ore, è esattamente quello che deve essere.

**Nessuna delle 31 funzioni con la guardia rotta è stata chiamata da un anonimo.**

## Cosa se ne ricava

La falla era aperta e verificata, ma in queste 24 ore nessuno l'ha usata. Il che vuol dire due cose.

La prima è che non c'è un incidente in corso da rincorrere, e il `03a` si può applicare con calma,
senza fretta e senza svegliare nessuno di notte.

La seconda è che 24 ore di log non sono una risposta sul passato. Se la domanda è *qualcuno ha già
scaricato quei 410 contatti*, la risposta onesta è che con i log di oggi non si può sapere.

## Da rieseguire dopo il 03a

Le stesse due query, il giorno dopo l'applicazione. La query 2 deve continuare a mostrare
`get_eventi_calendario` e `conteggi_prima_lezione`, e nient'altro. Se dopo il `03a` compare un
403 su una funzione del flusso pubblico, vuol dire che una revoca è andata oltre il bersaglio:

```sql
SELECT
  replaceRegexpOne(log_attributes['request.path'], '^.*/rest/v1/rpc/', '') AS funzione,
  log_attributes['response.status_code'] AS stato,
  count(*) AS n
FROM logs
WHERE source = 'edge_logs'
  AND position(log_attributes['request.path'], '/rest/v1/rpc/') > 0
  AND log_attributes['response.status_code'] IN ('401','403')
GROUP BY funzione, stato
ORDER BY n DESC;
```
