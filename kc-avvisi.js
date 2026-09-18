/* KC-BUILD: kc-avvisi v2 · 2026-09-18 · REGISTRO UNICO DEGLI AVVISI
 *
 * SCOPO — Censimento Avvisi v0.2. Ogni "no" che la persona incontra si dice qui, una
 * volta sola, in tre tempi: cosa è successo · la regola · cosa puoi fare ora. Nessun
 * testo del DB, della RPC o del Worker arriva alla persona senza passare da qui.
 *
 * LA REGOLA — Ogni testo diretto alla persona vive QUI, non nelle pagine. Una pagina
 * non scrive mai un avviso proprio: chiede il testo al registro. Un codice nuovo si
 * aggiunge in REGISTRO, dopo che Marco ha ratificato la frase.
 *
 * I NUMERI NON SI SCRIVONO NEI TESTI — ore, giorni, date e nomi di corso stanno nei
 * segnaposto {…} e li riempie chi chiama, leggendoli da tipi_corso_config o dai dati
 * già in pagina (P-VERITÀ-UNICA). Se un segnaposto resta vuoto è un difetto nostro:
 * il registro NON mostra mezza regola, ripiega su errore_tecnico e lo scrive in
 * console. I nomi dei corsi si passano per esteso, mai accorciati.
 *
 * ⚠ CACHE — sw.js serve i .js cache-first: il tag va scritto SEMPRE con la query di
 * versione e il ?v= va ALZATO a ogni modifica di questo file, altrimenti i telefoni
 * che hanno già visitato il sito continuano a eseguire la copia vecchia.
 * Versione query in uso: v=2.
 *
 * ⚠ TENUTA — Le pagine agganciano il registro dietro un `if (window.kcAvvisi)`: se
 * questo file non si carica devono comportarsi esattamente come prima. Una landing
 * con campagna attiva non può rompersi per un file mancante.
 *
 * v2 · 2026-09-18 — I testi del Censimento Avvisi, ratificati da Marco: agenda (A1-A15),
 *   landing (B1-B3), minori (C1), kata (E1-E2), pagine di servizio (F2). Aggiunti
 *   testo() con segnaposto e daErroreRpc(), che raccoglie in un punto solo la catena di
 *   traduzione dei RAISE di prenota_corso / disdici_corso (prima viveva dentro
 *   agenda.html onPrenotaConferma).
 * v1 · 2026-09-18 — Punti B5b e A14: i codici del Worker senza campo message
 *   (stripe_session_failed, rpc_gruppo_failed, gruppo_non_creato, price_id ...)
 *   non arrivano più nudi a chi sta per pagare.
 */
(function (global) {
  'use strict';

  var WHATSAPP_URL = 'https://wa.me/393318743953';
  var WHATSAPP_TESTO = 'Scrivici su WhatsApp';

  /* I testi. Unica fonte. {segnaposto} riempiti da chi chiama. */
  var REGISTRO = {

    /* — guasti nostri (v1) — */
    errore_pagamento_nostro: {
      testo: 'Il pagamento non si è aperto per un problema nostro. Non ti è stato addebitato nulla. Scrivici su WhatsApp e sistemiamo.',
      whatsapp: true
    },
    errore_tecnico: {
      testo: 'Qualcosa non ha funzionato dalla nostra parte. Riprova tra un minuto; se continua, scrivici su WhatsApp e sistemiamo.',
      whatsapp: true
    },
    errore_rete: {
      testo: 'Connessione instabile: riprova. Se continua, scrivici su WhatsApp e sistemiamo.',
      whatsapp: true
    },

    /* — agenda, vista allievo (A1-A15) — */
    disdetta_fuori_tempo: {
      testo: 'Disdetta chiusa. Una lezione si disdice fino a {ore_disdetta} ore prima: il posto che hai preso è un impegno verso di te e verso chi avrebbe potuto prenderlo. Per un imprevisto reale scrivici su WhatsApp.',
      whatsapp: true
    },
    disdette_esaurite: {
      testo: 'Hai usato tutte le disdette di questo corso. Per un imprevisto reale scrivici su WhatsApp.',
      whatsapp: true
    },
    slot_pieno: {
      testo: 'Pieno. Tutti i posti di questa lezione sono presi: scegli un\'altra lezione della settimana.',
      whatsapp: false
    },
    slot_pieno_gara: {
      testo: 'La lezione si è appena riempita. Scegli un\'altra lezione della settimana.',
      whatsapp: false
    },
    prenotazione_chiusa: {
      testo: 'Prenotazioni chiuse. Una lezione si prenota fino a {ore_prenotazione} ore prima. Scegli un\'altra lezione; se vuoi venire a questa, scrivici su WhatsApp.',
      whatsapp: true
    },
    credito_esaurito: {
      testo: 'Credito esaurito. Si prenotano le lezioni già pagate: per continuare il percorso passa in segreteria.',
      whatsapp: false
    },
    in_pausa: {
      testo: 'In pausa fino al {data}. Le lezioni di questo periodo non sono prenotabili. Per riprendere prima scrivici su WhatsApp.',
      whatsapp: true
    },
    corso_scaduto: {
      testo: 'Il tuo {corso} è scaduto il {data}. Ogni corso ha un tempo entro cui fare le lezioni. Passa in segreteria per rinnovare.',
      whatsapp: false
    },
    fuori_validita: {
      testo: 'Questa lezione cade dopo la scadenza del tuo corso ({data}). Scegli una data precedente oppure passa in segreteria per rinnovare.',
      whatsapp: false
    },
    corso_non_compatibile: {
      testo: 'Questa lezione è del {corso_slot}. Tu sei iscritto al {corso_tuo}: prenota le lezioni del tuo corso.',
      whatsapp: false
    },
    gia_prenotato_corso: {
      testo: 'Sei già prenotato a questa lezione.',
      whatsapp: false
    },
    nessun_corso_attivo: {
      testo: 'Nessun corso attivo. Passa in segreteria per attivare il percorso.',
      whatsapp: false
    },
    disdetta_tardiva_ok: {
      testo: 'Disdetta registrata. Fuori dalle {ore_disdetta} ore la lezione resta scalata dal credito.',
      whatsapp: false
    },

    /* — landing (B1-B3) e minori (C1) — */
    cutoff_oggi: {
      testo: 'Prenotazioni chiuse. Per oggi si prenota fino a {ore} ore prima dell\'inizio. Scegli un\'altra data o scrivici su WhatsApp.',
      whatsapp: true
    },
    esaurito_landing: {
      testo: 'Esaurito. Scegli un\'altra data.',
      whatsapp: false
    },
    fuori_finestra: {
      testo: 'Le date si aprono {giorni} giorni prima. Torna tra qualche giorno per le successive.',
      whatsapp: false
    },
    minori_da_domani: {
      testo: 'Le lezioni di bambini e ragazzi si prenotano entro il giorno prima: gli istruttori preparano la lezione sull\'età di chi arriva.',
      whatsapp: false
    },

    /* — area personale (E1-E2) e pagine di servizio (F2) — */
    kata_bloccato: {
      testo: 'Questo Kata si apre più avanti nel percorso. I Kata si aprono nell\'ordine in cui si incontrano nei corsi.',
      whatsapp: false
    },
    upload_errore: {
      testo: 'Il video non è stato caricato. Controlla la connessione e riprova; se il file è molto pesante prova con un video più corto.',
      whatsapp: false
    },
    link_scaduto: {
      testo: 'Questo link è scaduto. Chiedine uno nuovo dalla pagina di accesso.',
      whatsapp: false
    }
  };

  /* Guasti nostri sul checkout: il Worker li manda come codice secco, senza message. */
  var CODICI_PAGAMENTO = ['stripe_session_failed', 'rpc_gruppo_failed', 'gruppo_non_creato', 'price_id'];

  /* Indirizzi email: si tolgono dal testo prima di cercare gli underscore, altrimenti
     un mario_rossi@example.com farebbe scartare una frase scritta bene. */
  var EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]+/g;

  var SEGNAPOSTO = /\{([a-z_]+)\}/g;

  function stringa(v) {
    return (typeof v === 'string') ? v.trim() : '';
  }

  /* L'errore vero resta leggibile a noi, mai alla persona. */
  function registraInConsole(codice, status, body) {
    if (global.console && global.console.error) {
      global.console.error('[kc-avvisi] ' + codice + ' · status', status, '· body', body);
    }
  }

  /* Data ISO -> giorno/mese/anno. Solo formattazione: la data arriva dal DB o dalla
     pagina, qui non si inventa nulla. */
  function dataIt(v) {
    var s = stringa(v);
    var m = /(\d{4})-(\d{2})-(\d{2})/.exec(s);
    return m ? (m[3] + '/' + m[2] + '/' + m[1]) : s;
  }

  /* Compila la frase di un codice. Se un segnaposto resta vuoto la frase direbbe mezza
     regola, quindi non si usa: si ripiega su errore_tecnico e il buco finisce in console,
     perché è un difetto nostro da vedere, non da nascondere. */
  function testo(codice, valori) {
    var voce = REGISTRO[codice];
    if (!voce) {
      registraInConsole('codice sconosciuto: ' + codice, null, valori);
      return REGISTRO.errore_tecnico.testo;
    }
    var v = valori || {};
    var mancanti = [];
    var frase = voce.testo.replace(SEGNAPOSTO, function (intero, nome) {
      var valore = v[nome];
      if (valore === undefined || valore === null || valore === '') { mancanti.push(nome); return intero; }
      return (nome === 'data') ? dataIt(valore) : String(valore);
    });
    if (mancanti.length) {
      registraInConsole('segnaposto senza valore in "' + codice + '": ' + mancanti.join(', '), null, valori);
      return REGISTRO.errore_tecnico.testo;
    }
    return frase;
  }

  /* Avviso pronto da mostrare: { codice, testo, whatsapp }. */
  function daCodice(codice, valori) {
    if (!REGISTRO[codice]) codice = 'errore_tecnico';
    var frase = testo(codice, valori);
    /* se testo() ha dovuto ripiegare, ripiega anche il codice */
    if (frase === REGISTRO.errore_tecnico.testo && codice !== 'errore_tecnico') codice = 'errore_tecnico';
    return { codice: codice, testo: frase, whatsapp: REGISTRO[codice].whatsapp };
  }

  /* Frase che arriva già umana dal Worker: si mostra così com'è, senza aggiungere il
     link (quelle frasi l'invito a scriverci ce l'hanno già dentro). */
  function daFrase(frase) {
    return { codice: 'frase_dal_worker', testo: frase, whatsapp: false };
  }

  /* Frase già leggibile, cioè scritta per la persona e non per noi. Tre condizioni.
     (a) Ha spazi: un codice secco come stripe_session_failed non è una frase.
     (b) Lo status è sotto il 500. Da 500 in su il campo error non è mai destinato alla
         persona: è il guasto che racconta sé stesso ("duplicate key value violates
         unique constraint ..."). Il campo message resta valido a qualsiasi status,
         quello il Worker lo scrive apposta per chi legge.
     (c) Non contiene underscore, una volta tolti gli indirizzi email. Un underscore è
         il nome di un campo o di un vincolo, quindi roba nostra: "Slot Prima Lezione
         mancante (slot_id + data_lezione)" ha l'aria di una frase ma non lo è. Le email
         si tolgono prima perché il Worker le cita per esteso ("Email ripetuta nel
         gruppo: mario_rossi@example.com") e l'underscore lì dentro non conta.
     Restano umane le validazioni del Worker ("Persona 2: email non valida") e i
     messaggi età di inizia-giovani. */
  function eFraseUmana(s, status) {
    if (!s || s.indexOf(' ') === -1) return false;
    if (typeof status === 'number' && status >= 500) return false;
    return s.replace(EMAIL, '').indexOf('_') === -1;
  }

  function eGuastoPagamento(s) {
    var minuscolo = s.toLowerCase();
    for (var i = 0; i < CODICI_PAGAMENTO.length; i++) {
      if (minuscolo.indexOf(CODICI_PAGAMENTO[i]) !== -1) return true;
    }
    return false;
  }

  /* Decide cosa vede la persona a partire dalla risposta del Worker.
     Ordine: message umano · guasto nostro sul pagamento · error già umano · tutto il resto.
     NOTA: il guasto di pagamento si valuta PRIMA della frase umana, perché
     "price_id Prima Lezione non configurato" ha la forma di una frase ma è un guasto
     nostro, e alla persona non deve arrivare il nome di una variabile. */
  function daRisposta(status, body) {
    var corpo = (body && typeof body === 'object') ? body : {};
    var message = stringa(corpo.message);
    if (message) return daFrase(message);

    var error = stringa(corpo.error);
    if (error && eGuastoPagamento(error)) {
      registraInConsole('errore_pagamento_nostro', status, body);
      return daCodice('errore_pagamento_nostro');
    }
    if (eFraseUmana(error, status)) return daFrase(error);

    registraInConsole('errore_tecnico', status, body);
    return daCodice('errore_tecnico');
  }

  /* I RAISE di prenota_corso / disdici_corso, tradotti in un punto solo. Prima questa
     catena viveva dentro agenda.html (onPrenotaConferma): duplicarla significava che
     bastava cambiare una parola nella RPC per far saltare la traduzione in un posto e
     non nell'altro. Le regex restano sul testo italiano della RPC: è un ponte, finché
     prenota_corso e disdici_corso non restituiranno un codice loro.
     `contesto` porta i segnaposto (ore_prenotazione, ore_disdetta, corso, corso_slot,
     corso_tuo, data) letti da tipi_corso_config e dai dati di pagina. */
  var REGOLE_RPC = [
    { re: /Nessuna lezione residua/i,                       codice: 'credito_esaurito' },
    { re: /Nessun corso attivo|Nessuna iscrizione attiva/i, codice: 'nessun_corso_attivo' },
    { re: /Troppo tardi/i,                                  codice: 'prenotazione_chiusa' },
    { re: /In pausa fino al/i,                              codice: 'in_pausa' },
    { re: /oltre la fine validit/i,                         codice: 'fuori_validita' },
    { re: /non compatibile/i,                               codice: 'corso_non_compatibile' },
    { re: /gi[aà]'? una prenotazione attiva/i,              codice: 'gia_prenotato_corso' },
    { re: /Hai esaurito le \d+ disdette|disdette esaurite/i, codice: 'disdette_esaurite' },
    { re: /scadut/i,                                        codice: 'corso_scaduto' },
    { re: /Slot pieno/i,                                    codice: 'slot_pieno_gara' },
    /* ultima rete, come faceva agenda: un "pieno" da solo vale comunque */
    { re: /\bpieno\b/i,                                     codice: 'slot_pieno_gara' }
  ];

  /* La data utile dentro un messaggio della RPC. Quando ce n'e' piu' di una, quella che
     riguarda la persona e' la SCADENZA, non la data che ha chiesto: "La data lezione
     2026-10-30 e' oltre la fine validita' del pacchetto (2026-10-25)" deve dare il 25,
     altrimenti le si ripete la data che ha appena scelto come se fosse la scadenza.
     Quindi: la data tra parentesi se c'e', altrimenti l'ultima del messaggio. */
  function dataDalMessaggio(m) {
    var traParentesi = /\((\d{4}-\d{2}-\d{2})\)/.exec(m);
    if (traParentesi) return traParentesi[1];
    var tutte = m.match(/\d{4}-\d{2}-\d{2}/g);
    return tutte ? tutte[tutte.length - 1] : null;
  }

  /* copia il contesto aggiungendo la data, senza Object.assign (niente dipendenze) */
  function conData(ctx, data) {
    var fuori = { data: data };
    for (var k in ctx) { if (Object.prototype.hasOwnProperty.call(ctx, k)) fuori[k] = ctx[k]; }
    fuori.data = ctx.data || data;
    return fuori;
  }

  function daErroreRpc(messaggio, contesto) {
    var m = stringa(messaggio).replace(/^.*ERROR:\s*/i, '').replace(/^P0001:\s*/i, '');
    var ctx = contesto || {};
    for (var i = 0; i < REGOLE_RPC.length; i++) {
      if (REGOLE_RPC[i].re.test(m)) {
        var codice = REGOLE_RPC[i].codice;
        /* la data la porta il chiamante; se non ce l'ha, si prova a leggerla dal messaggio */
        if (!ctx.data && /\{data\}/.test(REGISTRO[codice].testo)) {
          var trovata = dataDalMessaggio(m);
          if (trovata) ctx = conData(ctx, trovata);
        }
        return daCodice(codice, ctx);
      }
    }
    registraInConsole('errore_tecnico (RPC non riconosciuta)', null, messaggio);
    return daCodice('errore_tecnico');
  }

  /* fetch fallita, rete caduta, richiesta interrotta. */
  function daEccezione(err) {
    registraInConsole('errore_rete', null, err);
    return daCodice('errore_rete');
  }

  /* Trasporta un avviso fino al catch della pagina senza perderlo per strada. */
  function errore(avviso) {
    var e = new Error(avviso && avviso.codice ? avviso.codice : 'errore_tecnico');
    e.kcAvviso = avviso || daCodice('errore_tecnico');
    return e;
  }

  /* Scrive l'avviso nell'elemento errore della pagina. textContent e createElement:
     mai innerHTML con testo che arriva da fuori. Ritorna l'elemento, così la pagina
     resta padrona di come lo rende visibile (classe .show, display, scroll). */
  function mostra(el, avviso) {
    if (!el || !avviso) return el || null;
    el.textContent = avviso.testo;
    if (avviso.whatsapp && global.document) {
      var riga = global.document.createElement('div');
      riga.className = 'kc-avviso-wa';
      var link = global.document.createElement('a');
      link.href = WHATSAPP_URL;
      link.target = '_blank';
      link.rel = 'noopener';
      link.textContent = WHATSAPP_TESTO;
      riga.appendChild(link);
      el.appendChild(riga);
    }
    return el;
  }

  global.kcAvvisi = {
    versione: 2,
    REGISTRO: REGISTRO,
    WHATSAPP_URL: WHATSAPP_URL,
    testo: testo,
    daCodice: daCodice,
    daRisposta: daRisposta,
    daErroreRpc: daErroreRpc,
    daEccezione: daEccezione,
    errore: errore,
    mostra: mostra
  };
})(typeof window !== 'undefined' ? window : this);
