/**
 * Arnaud Legoux Moving Average
 *
 * @see http://www.arnaudlegoux.com/
 */
#include <stdlib.mqh>


#property indicator_chart_window

#property indicator_buffers 3

#property indicator_width1  2
#property indicator_width2  2
#property indicator_width3  2


//////////////////////////////////////////////////////////////// Externe Parameter ////////////////////////////////////////////////////////////////

extern int    MA.Periods        = 200;                // averaging period
extern string MA.Timeframe      = "";                 // zu verwendender Timeframe (M1, M5, M15 etc. oder "" = aktueller Timeframe)

//extern int    MA.Periods        = 350;
//extern string MA.Timeframe      = "M30";

extern string AppliedPrice      = "Close";            // price used for MA calculation: Median=(H+L)/2, Typical=(H+L+C)/3, Weighted=(H+L+C+C)/4
extern string AppliedPrice.Help = "Open | High | Low | Close | Median | Typical | Weighted";
extern double GaussianOffset    = 0.85;               // Gaussian distribution offset (0..1)
extern double Sigma             = 6.0;
extern double PctReversalFilter = 0.0;                // minimum percentage MA change to indicate a trend change
extern int    Max.Values        = 2000;               // maximum number of indicator values to display: -1 = all

extern color  Color.UpTrend     = DodgerBlue;         // Farben hier konfigurieren, damit Code zur Laufzeit Zugriff hat
extern color  Color.DownTrend   = Orange;
extern color  Color.Reversal    = Yellow;

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


double iALMA[], iUpTrend[], iDownTrend[];             // sichtbare Indikatorbuffer
double iSMA[], iTrend[], iBarDiff[];                  // nicht sichtbare Buffer
double wALMA[];                                       // Gewichtungen der einzelnen Bars des MA

int    appliedPrice;
string objectLabels[], legendLabel, indicatorName;


/**
 * Initialisierung
 *
 * @return int - Fehlerstatus
 */
int init() {
   init = true; init_error = NO_ERROR; __SCRIPT__ = WindowExpertName();
   stdlib_init(__SCRIPT__);

   // Konfiguration auswerten
   if (MA.Periods < 2)
      return(catch("init(1)  Invalid input parameter MA.Periods = "+ MA.Periods, ERR_INVALID_INPUT_PARAMVALUE));

   MA.Timeframe = StringToUpper(StringTrim(MA.Timeframe));
   if (MA.Timeframe == "") int maTimeframe = Period();
   else                        maTimeframe = StringToPeriod(MA.Timeframe);
   if (maTimeframe == 0)
      return(catch("init(2)  Invalid input parameter MA.Timeframe = \""+ MA.Timeframe +"\"", ERR_INVALID_INPUT_PARAMVALUE));

   string price = StringToUpper(StringLeft(StringTrim(AppliedPrice), 1));
   if      (price == "O") appliedPrice = PRICE_OPEN;
   else if (price == "H") appliedPrice = PRICE_HIGH;
   else if (price == "L") appliedPrice = PRICE_LOW;
   else if (price == "C") appliedPrice = PRICE_CLOSE;
   else if (price == "M") appliedPrice = PRICE_MEDIAN;
   else if (price == "T") appliedPrice = PRICE_TYPICAL;
   else if (price == "W") appliedPrice = PRICE_WEIGHTED;
   else
      return(catch("init(3)  Invalid input parameter AppliedPrice = \""+ AppliedPrice +"\"", ERR_INVALID_INPUT_PARAMVALUE));

   // Buffer zuweisen
   IndicatorBuffers(6);
   SetIndexBuffer(0, iALMA     );      // nur f�r DataBox-Anzeige der aktuellen Werte (im Chart unsichtbar)
   SetIndexBuffer(1, iUpTrend  );
   SetIndexBuffer(2, iDownTrend);
   SetIndexBuffer(3, iSMA      );      // SMA-Zwischenspeicher f�r ALMA-Berechnung
   SetIndexBuffer(4, iTrend    );      // Trend (-1/+1) f�r jede einzelne Bar
   SetIndexBuffer(5, iBarDiff  );      // �nderung des ALMA-Values gegen�ber der vorherigen Bar (absolut)

   // Anzeigeoptionen
   if (MA.Timeframe != "")
      MA.Timeframe = StringConcatenate("x", MA.Timeframe);
   indicatorName = StringConcatenate("ALMA(", MA.Periods, MA.Timeframe, " / ", AppliedPriceDescription(appliedPrice), ")");
   IndicatorShortName(indicatorName);
   SetIndexLabel(0, indicatorName);
   SetIndexLabel(1, NULL);
   SetIndexLabel(2, NULL);
   IndicatorDigits(Digits);

   // Legende
   legendLabel = CreateLegendLabel(indicatorName);
   RegisterChartObject(legendLabel, objectLabels);

   // MA-Parameter nach Setzen der Label auf aktuellen Zeitrahmen umrechnen
   if (maTimeframe != Period()) {
      double minutes = maTimeframe * MA.Periods;               // Timeframe * Anzahl Bars = Range in Minuten
      MA.Periods = MathRound(minutes / Period());
   }

   // Zeichenoptionen
   int startDraw = MathMax(MA.Periods-1, Bars-ifInt(Max.Values < 0, Bars, Max.Values));
   SetIndexDrawBegin(0, startDraw);
   SetIndexDrawBegin(1, startDraw);
   SetIndexDrawBegin(2, startDraw);
   SetIndicatorStyles();                                       // Workaround um diverse Terminalbugs (siehe dort)

   // Gewichtungen berechnen
   if (MA.Periods > 1) {                                       // MA.Periods < 2 ist m�glich bei Umschalten auf zu gro�en Timeframe
      ArrayResize(wALMA, MA.Periods);
      int    m = MathRound(GaussianOffset * (MA.Periods-1));   // (int) double
      double s = MA.Periods / Sigma;
      double wSum;
      for (int i=0; i < MA.Periods; i++) {
         wALMA[i] = MathExp(-((i-m)*(i-m)) / (2*s*s));
         wSum += wALMA[i];
      }
      for (i=0; i < MA.Periods; i++) {
         wALMA[i] /= wSum;                                     // Gewichtungen der einzelnen Bars (Summe = 1)
      }
      ReverseDoubleArray(wALMA);                               // Reihenfolge umkehren, um in start() Zugriff zu beschleunigen
   }

   // nach Parameter�nderung nicht auf den n�chsten Tick warten (nur im "Indicators List" window notwendig)
   if (UninitializeReason() == REASON_PARAMETERS)
      SendTick(false);

   return(catch("init(4)"));
}


/**
 * Deinitialisierung
 *
 * @return int - Fehlerstatus
 */
int deinit() {
   RemoveChartObjects(objectLabels);
   RepositionLegend();
   return(catch("deinit()"));
}


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int start() {
   Tick++;
   if      (init_error != NO_ERROR)                   ValidBars = 0;
   else if (last_error == ERR_TERMINAL_NOT_YET_READY) ValidBars = 0;
   else                                               ValidBars = IndicatorCounted();
   ChangedBars = Bars - ValidBars;
   stdlib_onTick(ValidBars);

   // init() nach ERR_TERMINAL_NOT_YET_READY nochmal aufrufen oder abbrechen
   if (init_error == ERR_TERMINAL_NOT_YET_READY) /*&&*/ if (!init)
      init();
   init = false;
   if (init_error != NO_ERROR)
      return(init_error);

   // nach Terminal-Start Abschlu� der Initialisierung �berpr�fen
   if (Bars == 0 || ArraySize(iALMA) == 0) {
      last_error = ERR_TERMINAL_NOT_YET_READY;
      return(last_error);
   }
   last_error = 0;
   // -----------------------------------------------------------------------------


   // vor Neuberechnung alle Indikatorwerte zur�cksetzen
   if (ValidBars == 0) {
      ArrayInitialize(iALMA,      EMPTY_VALUE);
      ArrayInitialize(iUpTrend,   EMPTY_VALUE);
      ArrayInitialize(iDownTrend, EMPTY_VALUE);
      ArrayInitialize(iSMA,       EMPTY_VALUE);
      ArrayInitialize(iTrend,               0);
      SetIndicatorStyles();                        // Workaround um diverse Terminalbugs (siehe dort)
   }

   if (MA.Periods < 2)                             // Abbruch bei MA.Periods < 2 (m�glich bei Umschalten auf zu gro�en Timeframe)
      return(NO_ERROR);

   double filter;
   static int lastTrend;

   // Startbar ermitteln
   if (ChangedBars > Max.Values) /*&&*/ if (Max.Values >= 0)
      ChangedBars = Max.Values;
   int startBar = MathMin(ChangedBars-1, Bars-MA.Periods);


   // Laufzeitverteilung:  Schleife          -  5%
   // -------------------  iMA()             - 80%
   //                      Rechenoperationen - 15%
   //
   // Laptop vor Optimierung:
   // M5 - ALMA(350xM30)::start()   ALMA(2100)    startBar=1999   loop passes= 4.197.900   time1=203 msec   time2= 3125 msec   time3= 3766 msec
   // M1 - ALMA(350xM30)::start()   ALMA(10500)   startBar=1999   loop passes=20.989.500   time1=953 msec   time2=16094 msec   time3=18969 msec


   // Schleife �ber alle zu berechnenden Bars
   for (int bar=startBar; bar >= 0; bar--) {
      // der eigentliche Moving Average
      iALMA[bar] = 0;
      for (int i=0; i < MA.Periods; i++) {                           // Verwendung von iMA() ist nur f�r appliedPrice in (MEDIAN, TYPICAL, WEIGHTED) notwendig
         iALMA[bar] += wALMA[i] * iMA(NULL, NULL, 1, 0, MODE_SMA, appliedPrice, bar+i);
      }

      // Percentage-Filter f�r Reversal-Smoothing (verdoppelt Laufzeit und ist unsinnig implementiert)
      if (PctReversalFilter > 0) {
         iBarDiff[bar] = MathAbs(iALMA[bar] - iALMA[bar+1]);         // ALMA-�nderung gegen�ber der vorherigen Bar

         double sumDel = 0;
         for (int j=0; j < MA.Periods; j++) {
            sumDel += iBarDiff[bar+j];
         }
         double avgDel = sumDel/MA.Periods;                          // durchschnittliche ALMA-�nderung von Bar zu Bar

         double sumPow = 0;
         for (j=0; j < MA.Periods; j++) {
            sumPow += MathPow(iBarDiff[bar+j] - avgDel, 2);
         }
         filter = PctReversalFilter * MathSqrt(sumPow/MA.Periods);   // PctReversalFilter * stdDev

         if (iBarDiff[bar] < filter)
            iALMA[bar] = iALMA[bar+1];
      }

      // Trend coloring
      if      (iALMA[bar  ]-iALMA[bar+1] > filter) iTrend[bar] =  1;
      else if (iALMA[bar+1]-iALMA[bar  ] > filter) iTrend[bar] = -1;
      else                                         iTrend[bar] = iTrend[bar+1];

      if (iTrend[bar] > 0) {
         iUpTrend[bar] = iALMA[bar];
         if (iTrend[bar+1] < 0)
            iUpTrend[bar+1] = iALMA[bar+1];
      }
      else if (iTrend[bar] < 0) {
         iDownTrend[bar] = iALMA[bar];
         if (iTrend[bar+1] > 0)
            iDownTrend[bar+1] = iALMA[bar+1];
      }
      else {
         iUpTrend  [bar] = iALMA[bar];
         iDownTrend[bar] = iALMA[bar];
      }
   }

   // Legende aktualisieren
   if (iTrend[0] != lastTrend) {
      if      (iTrend[0] > 0) color fontColor = Color.UpTrend;
      else if (iTrend[0] < 0)       fontColor = Color.DownTrend;
      else                          fontColor = Color.Reversal;
      ObjectSetText(legendLabel, indicatorName, 9, "Arial Fett", fontColor);
      int error = GetLastError();
      if (error!=NO_ERROR) /*&&*/ if (error!=ERR_OBJECT_DOES_NOT_EXIST)    // bei offenem Properties-Dialog oder Object::onDrag()
         return(catch("start(1)", error));
   }
   lastTrend = iTrend[0];

   //if (startBar > 1) debug("start()  ALMA("+ MA.Periods +")   startBar: "+ startBar +"   time: "+ (GetTickCount()-tick) +" msec");
   return(catch("start(2)"));
}


/**
 * Indikator-Styles setzen. Workaround um diverse Terminalbugs (Farb�nderungen nach Recompile, Parameter�nderung etc.), die erfordern,
 * da� die Styles manchmal in init() und manchmal in start() gesetzt werden m�ssen, um korrekt angezeigt zu werden.
 */
void SetIndicatorStyles() {
   SetIndexStyle(0, DRAW_NONE, EMPTY, EMPTY, CLR_NONE       );
   SetIndexStyle(1, DRAW_LINE, EMPTY, EMPTY, Color.UpTrend  );
   SetIndexStyle(2, DRAW_LINE, EMPTY, EMPTY, Color.DownTrend);
}
