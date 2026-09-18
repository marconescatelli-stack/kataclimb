/* KC-BUILD: kc-avvisi v1 · 2026-09-18 · REGISTRO UNICO DEGLI AVVISI
 *
 * SCOPO — Censimento Avvisi v0.2, punti B5b e A14: quando il Worker risponde con un
 * codice e senza campo `message` (stripe_session_failed, rpc_gruppo_failed,
 * gruppo_non_creato, "price_id ... non configurato", 500 a corpo vuoto), la parola
 * tecnica nuda finiva davanti a una persona pronta a pagare. Qui quei codici
 * diventano frasi: cosa è successo · la regola · cosa puoi fare ora.
 *
 * LA REGOLA — Ogni testo diretto alla persona vive QUI, non nelle pagine. Una landing
 * non scrive mai un avviso proprio: chiede il testo al registro. Un codice nuovo si
 * aggiunge in REGISTRO, dopo che Marco ha ratificato la frase.
 *
 * ⚠ CACHE — sw.js serve i .js cache-first: il tag va scritto SEMPRE con la query di
 * versione, <script src="/kc-avvisi.js?v=1"></script>, e il ?v= va ALZATO a ogni
 * modifica di questo file, altrimenti i telefoni che hanno già visitato il sito
 * continuano a eseguire la copia vecchia. Versione query in uso: v=1.
 *
 * ⚠ TENUTA — Le pagine agganciano il registro dietro un `if (window.kcAvvisi)`: se
 * questo file non si carica devono comportarsi esattamente come prima. Una landing
 * con campagna attiva non può rompersi per un file mancante.
 *
 * In v1 sono agganciate inizia, inizia-dopo, inizia-giovani, sumisura (tre rami
 * ciascuna: checkout singolo, checkout gruppo, invio richiesta). Fuori da v1:
 * agenda, kata, inizia-minori, inizia-famiglia, portale.
 */
(function (global) {
  'use strict';

  var WHATSAPP_URL = 'https://wa.me/393318743953';
  var WHATSAPP_TESTO = 'Scrivici su WhatsApp';

  /* I testi. Unica fonte. */
  var REGISTRO = {
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
    }
  };

  /* Guasti nostri sul checkout: il Worker li manda come codice secco, senza message. */
  var CODICI_PAGAMENTO = ['stripe_session_failed', 'rpc_gruppo_failed', 'gruppo_non_creato', 'price_id'];

  /* snake_case puro = codice tecnico, non una frase per la persona. */
  var SNAKE = /^[a-z0-9]+(?:_[a-z0-9]+)+$/;

  function stringa(v) {
    return (typeof v === 'string') ? v.trim() : '';
  }

  /* Frase già leggibile: ha spazi e non è un codice. Copre le validazioni del Worker
     ("Persona 2: email non valida") e i messaggi età di inizia-giovani. */
  function eFraseUmana(s) {
    return !!s && s.indexOf(' ') !== -1 && !SNAKE.test(s);
  }

  function eGuastoPagamento(s) {
    var minuscolo = s.toLowerCase();
    for (var i = 0; i < CODICI_PAGAMENTO.length; i++) {
      if (minuscolo.indexOf(CODICI_PAGAMENTO[i]) !== -1) return true;
    }
    return false;
  }

  /* L'errore vero resta leggibile a noi, mai alla persona. */
  function registraInConsole(codice, status, body) {
    if (global.console && global.console.error) {
      global.console.error('[kc-avvisi] ' + codice + ' · status', status, '· body', body);
    }
  }

  function daCodice(codice) {
    var voce = REGISTRO[codice] ? codice : 'errore_tecnico';
    return { codice: voce, testo: REGISTRO[voce].testo, whatsapp: REGISTRO[voce].whatsapp };
  }

  /* Frase che arriva già umana dal Worker: si mostra così com'è, senza aggiungere il
     link (quelle frasi l'invito a scriverci ce l'hanno già dentro). */
  function daFrase(testo) {
    return { codice: 'frase_dal_worker', testo: testo, whatsapp: false };
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
    if (eFraseUmana(error)) return daFrase(error);

    registraInConsole('errore_tecnico', status, body);
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
    versione: 1,
    REGISTRO: REGISTRO,
    WHATSAPP_URL: WHATSAPP_URL,
    daRisposta: daRisposta,
    daEccezione: daEccezione,
    daCodice: daCodice,
    errore: errore,
    mostra: mostra
  };
})(typeof window !== 'undefined' ? window : this);
