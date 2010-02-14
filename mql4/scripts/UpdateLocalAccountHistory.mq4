
#include <stdlib.mqh>

//#property show_confirm
//#property show_inputs


/**
 *
 */
int start() {
   int tick = GetTickCount();
   int error, account=AccountNumber(), orders=OrdersHistoryTotal();


   // Sortierschl�ssel: CloseTime, OpenTime, Ticket
   int ticketData[][3];
   ArrayResize(ticketData, 0); ArrayResize(ticketData, orders);


   // Sortierschl�ssel aller Tickets aus Online-History auslesen und Tickets sortieren
   for (int i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         return(catch("start(1)  OrderSelect(pos="+ i +")"));
      ticketData[i][0] = OrderCloseTime();
      ticketData[i][1] = OrderOpenTime();
      ticketData[i][2] = OrderTicket();
   }
   SortTickets(ticketData);


   // letztes bereits gespeichertes Ticket und dessen Balance ermitteln
   int    lastTicket;
   double lastBalance;
   string history[][HISTORY_COLUMNS]; ArrayResize(history, 0);
   GetAccountHistory(account, history);

   i = ArrayRange(history, 0);
   if (i > 0) {
      lastTicket  = StrToInteger(history[i-1][HC_TICKET ]);
      lastBalance = StrToDouble (history[i-1][HC_BALANCE]);
   }
   if (orders == 0) if (lastBalance != AccountBalance())
      return(catch("start(2)  more history data needed", ERR_RUNTIME_ERROR));


   // Index des ersten ungespeicherten Tickets suchen
   int startIndex = 0;
   if (ArrayRange(history, 0) > 0) {
      for (i=0; i < orders; i++) {
         if (ticketData[i][2] == lastTicket) {
            startIndex = i+1;
            break;
         }
      }
   }


   // Hilfsvariablen
   int      n, ticket, type;
   int      tickets[];           ArrayResize(tickets,           0); ArrayResize(tickets,           orders);
   int      types[];             ArrayResize(types,             0); ArrayResize(types,             orders);
   double   sizes[];             ArrayResize(sizes,             0); ArrayResize(sizes,             orders);
   string   symbols[];           ArrayResize(symbols,           0); ArrayResize(symbols,           orders);
   datetime openTimes[];         ArrayResize(openTimes,         0); ArrayResize(openTimes,         orders);
   datetime closeTimes[];        ArrayResize(closeTimes,        0); ArrayResize(closeTimes,        orders);
   double   openPrices[];        ArrayResize(openPrices,        0); ArrayResize(openPrices,        orders);
   double   closePrices[];       ArrayResize(closePrices,       0); ArrayResize(closePrices,       orders);
   double   stopLosses[];        ArrayResize(stopLosses,        0); ArrayResize(stopLosses,        orders);
   double   takeProfits[];       ArrayResize(takeProfits,       0); ArrayResize(takeProfits,       orders);
   double   commissions[];       ArrayResize(commissions,       0); ArrayResize(commissions,       orders);
   double   swaps[];             ArrayResize(swaps,             0); ArrayResize(swaps,             orders);
   double   netProfits[];        ArrayResize(netProfits,        0); ArrayResize(netProfits,        orders);
   double   grossProfits[];      ArrayResize(grossProfits,      0); ArrayResize(grossProfits,      orders);
   double   normalizedProfits[]; ArrayResize(normalizedProfits, 0); ArrayResize(normalizedProfits, orders);
   double   balances[];          ArrayResize(balances,          0); ArrayResize(balances,          orders);
   datetime expTimes[];          ArrayResize(expTimes,          0); ArrayResize(expTimes,          orders);
   int      magicNumbers[];      ArrayResize(magicNumbers,      0); ArrayResize(magicNumbers,      orders);
   string   comments[];          ArrayResize(comments,          0); ArrayResize(comments,          orders);


   // History sortiert auslesen und zwischenspeichern (um gehedgte Positionen korrigieren zu k�nnen)
   for (i=startIndex; i < orders; i++) {
      ticket = ticketData[i][2];
      if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
         return(catch("start(3)  OrderSelect(ticket="+ ticket +")"));

      // gestrichene Orders und Kreditlinien sind keine Transaktionen -> �berspringen
      type = OrderType();
      if (type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP || type==OP_MARGINCREDIT)
         continue;

      tickets     [n] = ticket;
      types       [n] = type;
      sizes       [n] = OrderLots();
      symbols     [n] = OrderSymbol();
      openTimes   [n] = OrderOpenTime();
      closeTimes  [n] = OrderCloseTime();
      openPrices  [n] = OrderOpenPrice();
      closePrices [n] = OrderClosePrice();
      stopLosses  [n] = OrderStopLoss();
      takeProfits [n] = OrderTakeProfit();
      commissions [n] = OrderCommission();
      swaps       [n] = OrderSwap();
      netProfits  [n] = OrderProfit();
      expTimes    [n] = OrderExpiration();   // GrossProfit, NormalizedProfit und Balance werden sp�ter berechnet
      magicNumbers[n] = OrderMagicNumber();
      comments    [n] = OrderComment();
      n++;
   }


   // Arrays justieren
   if (n < orders) {
      ArrayResize(tickets,           n);
      ArrayResize(types,             n);
      ArrayResize(sizes,             n);
      ArrayResize(symbols,           n);
      ArrayResize(openTimes,         n);
      ArrayResize(closeTimes,        n);
      ArrayResize(openPrices,        n);
      ArrayResize(closePrices,       n);
      ArrayResize(stopLosses,        n);
      ArrayResize(takeProfits,       n);
      ArrayResize(commissions,       n);
      ArrayResize(swaps,             n);
      ArrayResize(netProfits,        n);
      ArrayResize(grossProfits,      n);
      ArrayResize(normalizedProfits, n);
      ArrayResize(balances,          n);
      ArrayResize(expTimes,          n);
      ArrayResize(magicNumbers,      n);
      ArrayResize(comments,          n);
      orders = n;
   }


   // gehedgte Positionen korrigieren (Gr��e, ClosePrice, Commission, Swap, NetProfit)
   for (i=0; i < orders; i++) {
      if (sizes[i] == 0) {
         if (StringSubstr(comments[i], 0, 16) != "close hedge by #")
            return(catch("start(4)  transaction "+ tickets[i] +" - unknown comment for hedged position: "+ comments[i], ERR_RUNTIME_ERROR));

         // Gegenst�ck der Position suchen
         ticket = StrToInteger(StringSubstr(comments[i], 16));
         for (n=0; n < orders; n++)
            if (tickets[n] == ticket)
               break;
         if (n == orders)
            return(catch("start(5)  cannot find counterpart position #"+ ticket +" for hedged position #"+ tickets[i], ERR_RUNTIME_ERROR));

         // zeitliche Reihenfolge bestimmen
         int first, second;
         if      (openTimes[i] < openTimes[n]) { first = i; second = n; }
         else if (openTimes[i] > openTimes[n]) { first = n; second = i; }
         else if (tickets[i]   < tickets[n]  ) { first = i; second = n; }  // beide zum selben Zeitpunkt er�ffnet: unwahrscheinlich, doch nicht unm�glich
         else                                  { first = n; second = i; }

         // Orderdaten korrigieren
         sizes[i]       = sizes[n];
         closePrices[i] = openPrices[second];   // ClosePrice ist der OpenPrice der sp�teren Position (sie hedgt die fr�here Position)
         closePrices[n] = openPrices[second];

         commissions[first] = commissions[n];   // der gesamte Profit/Loss wird der gehedgten Postion zugerechnet
         swaps      [first] = swaps      [n];
         netProfits [first] = netProfits [n];

         commissions[second] = 0;               // die hedgende Position verursacht keine Kosten
         swaps      [second] = 0;
         netProfits [second] = 0;
      }
   }


   // GrossProfit und Balance berechnen und mit dem in der History gespeicherten letzten Wert gegenpr�fen
   for (i=0; i < orders; i++) {
      grossProfits[i] = NormalizeDouble(netProfits[i] + commissions[i] + swaps[i], 2);
      balances[i]     = NormalizeDouble(lastBalance + grossProfits[i], 2);
      lastBalance = balances[i];
   }
   if (lastBalance != AccountBalance()) {
      Print("start()  balance mismatch - calculated: "+ DoubleToStr(lastBalance, 2) +"   online: "+ DoubleToStr(AccountBalance(), 2));
      return(catch("start(6)  more history data needed", ERR_RUNTIME_ERROR));
   }


   // R�ckkehr, wenn lokale History aktuell ist
   if (orders == 0) {
      Print("start()  local history is up to date");
      MessageBox("History up to date", "Script", MB_ICONINFORMATION | MB_OK);
      return(catch("start(7)"));
   }


   // Alle Daten ok: Datei schreiben
   int handle;

   // Ist die Historydatei leer, wird sie neugeschrieben. Andererseits werden die neuen Daten am Ende angef�gt.
   if (ArrayRange(history, 0) == 0) {
      // Datei neu erzeugen (und ggf. l�schen)
      handle = FileOpen(account +"/account history.csv", FILE_CSV|FILE_WRITE, '\t');
      if (handle < 0)
         return(catch("start(8)  FileOpen()"));

      // Header schreiben
      int    iOffset   = GetServerGMTOffset();
      string strOffset = DoubleToStr(MathAbs(iOffset), 0);

      if (MathAbs(iOffset) < 10) strOffset = "0"+ strOffset;
      if (iOffset < 0)           strOffset = "-"+ strOffset;
      else                       strOffset = "+"+ strOffset;

      string header = "# History for account no. "+ account +" at "+ AccountCompany() +" (ordered by CloseTime+OpenTime+Ticket, transaction times are GMT"+ strOffset +":00)\n"
                    + "#";
      if (FileWrite(handle, header) < 0) {
         error = GetLastError();
         FileClose(handle);
         return(catch("start(11)  FileWrite()", error));
      }
      if (FileWrite(handle, "Ticket","OpenTime","OpenTimestamp","Description","Type","Size","Symbol","OpenPrice","StopLoss","TakeProfit","CloseTime","CloseTimestamp","ClosePrice","ExpirationTime","ExpirationTimestamp","MagicNumber","Commission","Swap","NetProfit","GrossProfit","NormalizedProfit","Balance","Comment") < 0) {
         error = GetLastError();
         FileClose(handle);
         return(catch("start(9)  FileWrite()", error));
      }
   }
   // Historydatei enth�lt bereits Daten, �ffnen und FilePointer ans Ende setzen
   else {
      handle = FileOpen(account +"/account history.csv", FILE_CSV|FILE_READ|FILE_WRITE, '\t');
      if (handle < 0)
         return(catch("start(10)  FileOpen()"));
      if (!FileSeek(handle, 0, SEEK_END)) {
         error = GetLastError();
         FileClose(handle);
         return(catch("start(11)  FileSeek()", error));
      }
   }


   // Orderdaten schreiben
   for (i=0; i < orders; i++) {
      string strType = GetOperationTypeDescription(types[i]);
      string strSize = ""; if (types[i] < OP_BALANCE) strSize = DoubleToStrTrim(sizes[i]);

      string strOpenTime  = TimeToStr(openTimes [i], TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      string strCloseTime = TimeToStr(closeTimes[i], TIME_DATE|TIME_MINUTES|TIME_SECONDS);

      string strOpenPrice  = ""; if (openPrices [i] > 0) strOpenPrice  = DoubleToStrTrim(openPrices [i]);
      string strClosePrice = ""; if (closePrices[i] > 0) strClosePrice = DoubleToStrTrim(closePrices[i]);
      string strStopLoss   = ""; if (stopLosses [i] > 0) strStopLoss   = DoubleToStrTrim(stopLosses [i]);
      string strTakeProfit = ""; if (takeProfits[i] > 0) strTakeProfit = DoubleToStrTrim(takeProfits[i]);

      string strExpTime="", strExpTimestamp="";
      if (expTimes[i] > 0) {
         strExpTime      = TimeToStr(expTimes[i], TIME_DATE|TIME_MINUTES|TIME_SECONDS);
         strExpTimestamp = expTimes[i];
      }
      string strMagicNumber = ""; if (magicNumbers[i] != 0) strMagicNumber = magicNumbers[i];

      string strCommission       = DoubleToStr(commissions [i], 2);
      string strSwap             = DoubleToStr(swaps       [i], 2);
      string strNetProfit        = DoubleToStr(netProfits  [i], 2);
      string strGrossProfit      = DoubleToStr(grossProfits[i], 2);
      string strNormalizedProfit = "0.0";
      string strBalance          = DoubleToStr(balances    [i], 2);

      if (FileWrite(handle, tickets[i],strOpenTime,openTimes[i],strType,types[i],strSize,symbols[i],strOpenPrice,strStopLoss,strTakeProfit,strCloseTime,closeTimes[i],strClosePrice,strExpTime,strExpTimestamp,strMagicNumber,strCommission,strSwap,strNetProfit,strGrossProfit,strNormalizedProfit,strBalance,comments[i]) < 0) {
         error = GetLastError();
         FileClose(handle);
         return(catch("start(12)  FileWrite()", error));
      }
   }
   FileClose(handle);


   Print("start()  written history entries: ", orders, ", execution time: ", GetTickCount()-tick, " ms");
   MessageBox("History successfully updated", "Script", MB_ICONINFORMATION | MB_OK);
   return(catch("start(13)"));
}


/**
 *
 */
int SortTickets(int& tickets[][/*{CloseTime, OpenTime, Ticket}*/]) {
   if (ArrayRange(tickets, 1) != 3)
      return(catch("SortTickets(1)  invalid parameter tickets["+ ArrayRange(tickets, 0) +"]["+ ArrayRange(tickets, 1) +"]", ERR_INCOMPATIBLE_ARRAYS));

   if (ArrayRange(tickets, 0) < 2)
      return(catch("SortTickets(2)"));


   // zuerst alles nach CloseTime sortieren
   ArraySort(tickets);

   int close, open, ticket;
   int lastClose=0, lastOpen=0, n=0;


   // Datens�tze mit derselben CloseTime nach OpenTime sortieren
   int sameClose[1][3]; ArrayResize(sameClose, 0); ArrayResize(sameClose, 1);    // {OpenTime, Ticket, index}
   int count = ArrayRange(tickets, 0);

   for (int i=0; i < count; i++) {
      close  = tickets[i][0];
      open   = tickets[i][1];
      ticket = tickets[i][2];

      if (close == lastClose) {
         n++;
         ArrayResize(sameClose, n+1);
      }
      else if (n > 0) {
         // in sameClose gesammelte Werte neu sortieren
         ResortSameCloseTickets(sameClose, tickets);
         ArrayResize(sameClose, 1);
         n = 0;
      }

      sameClose[n][0] = open;
      sameClose[n][1] = ticket;
      sameClose[n][2] = i;       // Original-Position des Datensatzes in tickets

      lastClose = close;
   }
   // im letzten Schleifendurchlauf in sameClose gesammelte Werte m�ssen extra sortiert werden
   if (n > 0) {
      ResortSameCloseTickets(sameClose, tickets);
      n = 0;
   }


   // Datens�tze mit derselben Close- und OpenTime nach Ticket sortieren
   int sameCloseOpen[1][2]; ArrayResize(sameCloseOpen, 0); ArrayResize(sameCloseOpen, 1); // {Ticket, index}

   for (i=0; i < count; i++) {
      close  = tickets[i][0];
      open   = tickets[i][1];
      ticket = tickets[i][2];

      if (close==lastClose && open==lastOpen) {
         n++;
         ArrayResize(sameCloseOpen, n+1);
      }
      else if (n > 0) {
         // in sameCloseOpen gesammelte Werte neu sortieren
         ResortSameCloseOpenTickets(sameCloseOpen, tickets);
         ArrayResize(sameCloseOpen, 1);
         n = 0;
      }

      sameCloseOpen[n][0] = ticket;
      sameCloseOpen[n][1] = i;

      lastClose = close;
      lastOpen  = open;
   }
   // im letzten Schleifendurchlauf in sameCloseOpen gesammelte Werte m�ssen extra sortiert werden
   if (n > 0)
      ResortSameCloseOpenTickets(sameCloseOpen, tickets);

   return(catch("SortTickets(3)"));
}


/**
 *
 */
int ResortSameCloseTickets(int sameClose[][/*{OpenTime, Ticket, index}*/], int& tickets[][/*{CloseTime, OpenTime, Ticket}*/]) {
   int open, ticket, i;

   int sameCloseCopy[][3]; ArrayResize(sameCloseCopy, 0);
   ArrayCopy(sameCloseCopy, sameClose);   // Original-Reihenfolge der Indizes in Kopie speichern
   ArraySort(sameClose);                  // und nach OpenTime sortieren...

   int count = ArrayRange(sameClose, 0);

   for (int n=0; n < count; n++) {
      open   = sameClose    [n][0];
      ticket = sameClose    [n][1];
      i      = sameCloseCopy[n][2];
      tickets[i][1] = open;               // Original-Daten mit den sortierten Werten �berschreiben
      tickets[i][2] = ticket;
   }

   return(catch("ResortSameCloseTickets()"));
}


/**
 *
 */
int ResortSameCloseOpenTickets(int sameCloseOpen[][/*{Ticket, index}*/], int& tickets[][/*{OpenTime, CloseTime, Ticket}*/]) {
   int ticket=0, i=0;

   int sameCloseOpenCopy[][2]; ArrayResize(sameCloseOpenCopy, 0);
   ArrayCopy(sameCloseOpenCopy, sameCloseOpen); // Original-Reihenfolge der Indizes in Kopie speichern
   ArraySort(sameCloseOpen);                    // und nach Ticket sortieren...

   int count = ArrayRange(sameCloseOpen, 0);

   for (int n=0; n < count; n++) {
      ticket = sameCloseOpen    [n][0];
      i      = sameCloseOpenCopy[n][1];
      tickets[i][2] = ticket;                   // Original-Daten mit den sortierten Werten �berschreiben
   }

   return(catch("ResortSameCloseOpenTickets()"));
}

