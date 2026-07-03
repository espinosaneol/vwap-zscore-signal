//+------------------------------------------------------------------+
//|                                    VWAP_ZScore_Signal_Script.mq4 |
//|        Señal Z-score con W optimo auto-detectado                 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Trade App Soft LLC"
#property strict
#property script_show_inputs

//--- Inputs
input int    N         = 512;   // Barras M1 para estimar el modelo
input int    Wmin      = 15;    // Ventana minima permitida para W optimo
input double ZUmbral   = 1.65;  // Umbral Z (1.28=80%, 1.65=90%, 1.96=95%)
input int    Suavizado = 5;     // Ventana de suavizado del ratio (puntos)

//--- Variables globales del modelo
double g_dlog[];          // log returns poblacionales (N-1 elementos)
double g_muVentanas[];    // medias rolling con W optimo
double g_Zvector[];       // Z-score de cada ventana
double g_ratioVec[];      // ratio real/teorico para cada W
double g_ratioSuav[];     // ratio suavizado
double g_sigmaPob;        // desvio estandar poblacional
double g_sigmamuV;        // desvio estandar de las medias de ventana (W optimo)
double g_ratio;           // ratio en W optimo
double g_Zactual;         // Z-score de la ventana mas reciente
double g_muActual;        // media de la ventana mas reciente
int    g_Woptimo;         // W donde ratio suavizado es maximo

//--- Prototipos
double CalcMedia(double &arr[], int start, int period);
double CalcDesvio(double &arr[], int start, int period);
void   CalcDlogVwap(double &vwap[], double &dlog[]);
bool   CargarDatos(double &vwap[]);
void   BuscarWoptimo();
void   EstimarModelo();
void   EvaluarSenal();
void   ExportCSV(double &arr[], string filename);
void   ExportIntCSV(int &arr[], string filename);

//+------------------------------------------------------------------+
void OnStart()
{
   double Vwap[];

   if (!CargarDatos(Vwap)) return;
   CalcDlogVwap(Vwap, g_dlog);
   BuscarWoptimo();
   EstimarModelo();
   EvaluarSenal();

   ExportCSV(g_Zvector,    "Zvector.csv");
   ExportCSV(g_muVentanas, "muVentanas.csv");
   ExportCSV(g_ratioSuav,  "ratioSuavizado.csv");

   Alert("W optimo=", g_Woptimo,
         " | Z actual=", DoubleToString(g_Zactual, 4),
         " | Umbral=",   DoubleToString(ZUmbral,   2));
}

//+------------------------------------------------------------------+
//| Carga N velas M1 y calcula VWAP                                  |
//+------------------------------------------------------------------+
bool CargarDatos(double &vwap[])
{
   double o[], h[], l[], c[];
   if (CopyOpen (_Symbol, PERIOD_M1, 0, N, o) != N ||
       CopyHigh (_Symbol, PERIOD_M1, 0, N, h) != N ||
       CopyLow  (_Symbol, PERIOD_M1, 0, N, l) != N ||
       CopyClose(_Symbol, PERIOD_M1, 0, N, c) != N)
   { Alert("Error datos M1: ", GetLastError()); return false; }

   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   ArrayResize(vwap, N);
   for (int i = 0; i < N; i++)
      vwap[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
   return true;
}

//+------------------------------------------------------------------+
//| Busca W optimo como maximo del ratio suavizado                   |
//+------------------------------------------------------------------+
void BuscarWoptimo()
{
   int M    = ArraySize(g_dlog);
   int Wmax = M / 2;

   ArrayResize(g_ratioVec,  Wmax);
   ArrayResize(g_ratioSuav, Wmax);

   g_sigmaPob = CalcDesvio(g_dlog, 0, M);

   //--- Calcular ratio para cada W
   for (int w = 1; w <= Wmax; w++)
   {
      int    nV      = M - w + 1;
      double muV[];
      ArrayResize(muV, nV);
      for (int i = 0; i < nV; i++)
         muV[i] = CalcMedia(g_dlog, i, w);

      double sigmamuV = CalcDesvio(muV, 0, nV);
      double teorico  = g_sigmaPob / MathSqrt(w);
      g_ratioVec[w-1] = (teorico > 0) ? sigmamuV / teorico : 0;
   }

   //--- Suavizar ratio con promedio movil de Suavizado puntos
   int mitad = Suavizado / 2;
   for (int w = 0; w < Wmax; w++)
   {
      int desde = MathMax(0,    w - mitad);
      int hasta = MathMin(Wmax, w + mitad + 1);
      g_ratioSuav[w] = CalcMedia(g_ratioVec, desde, hasta - desde);
   }

   //--- Buscar maximo del ratio suavizado, restringido a W >= Wmin
   int wIni    = MathMax(1, Wmin);
   int    idxMax   = wIni - 1;
   double maxRatio = g_ratioSuav[wIni - 1];
   for (int w = wIni; w <= Wmax; w++)
   {
      if (g_ratioSuav[w-1] > maxRatio)
      { maxRatio = g_ratioSuav[w-1]; idxMax = w-1; }
   }

   g_Woptimo = idxMax + 1;
   Print("W optimo=", g_Woptimo,
         " | ratio suavizado maximo=", DoubleToString(maxRatio, 4));
}

//+------------------------------------------------------------------+
//| Estima sigmamuV y Zvector usando g_Woptimo                       |
//+------------------------------------------------------------------+
void EstimarModelo()
{
   int M  = ArraySize(g_dlog);
   int nV = M - g_Woptimo + 1;

   ArrayResize(g_muVentanas, nV);
   ArrayResize(g_Zvector,    nV);

   for (int i = 0; i < nV; i++)
      g_muVentanas[i] = CalcMedia(g_dlog, i, g_Woptimo);

   g_sigmamuV = CalcDesvio(g_muVentanas, 0, nV);
   g_ratio    = g_sigmamuV / (g_sigmaPob / MathSqrt(g_Woptimo));

   for (int i = 0; i < nV; i++)
      g_Zvector[i] = g_muVentanas[i] * MathSqrt(g_Woptimo) / g_sigmaPob;

   Print("sigma_pob=", DoubleToString(g_sigmaPob, 8),
         " sigmamuV=", DoubleToString(g_sigmamuV, 8),
         " ratio=",    DoubleToString(g_ratio,    4));
}

//+------------------------------------------------------------------+
//| Evalua la señal sobre la ventana mas reciente                    |
//+------------------------------------------------------------------+
void EvaluarSenal()
{
   g_muActual = CalcMedia(g_dlog, 0, g_Woptimo);
   g_Zactual  = g_muActual * MathSqrt(g_Woptimo) / g_sigmaPob;

   Print("muActual=", DoubleToString(g_muActual, 8),
         " Z=",       DoubleToString(g_Zactual,  4),
         " Umbral=",  DoubleToString(ZUmbral,    2));

   if      (g_Zactual >  ZUmbral)
      Print(">>> VENTA  | reversion bajista esperada");
   else if (g_Zactual < -ZUmbral)
      Print(">>> COMPRA | reversion alcista esperada");
   else
      Print(">>> SIN SEÑAL");
}

//+------------------------------------------------------------------+
void CalcDlogVwap(double &vwap[], double &dlog[])
{
   int s = ArraySize(vwap);
   ArrayResize(dlog, s - 1);
   for (int i = 0; i < s - 1; i++)
      dlog[i] = MathLog(vwap[i]) - MathLog(vwap[i+1]);
}

//+------------------------------------------------------------------+
double CalcMedia(double &arr[], int start, int period)
{
   double s = 0;
   for (int i = start; i < start + period; i++) s += arr[i];
   return s / period;
}

//+------------------------------------------------------------------+
double CalcDesvio(double &arr[], int start, int period)
{
   double m = CalcMedia(arr, start, period), s = 0;
   for (int i = start; i < start + period; i++)
      s += MathPow(arr[i] - m, 2);
   return MathSqrt(s / period);
}

//+------------------------------------------------------------------+
void ExportCSV(double &arr[], string filename)
{
   int fh = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI);
   if (fh == INVALID_HANDLE) { Alert("Error: ", filename); return; }
   for (int i = 0; i < ArraySize(arr); i++) FileWrite(fh, arr[i]);
   FileClose(fh);
   Print("Exportado: ", filename);
}

//+------------------------------------------------------------------+
void ExportIntCSV(int &arr[], string filename)
{
   int fh = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI);
   if (fh == INVALID_HANDLE) { Alert("Error: ", filename); return; }
   for (int i = 0; i < ArraySize(arr); i++) FileWrite(fh, arr[i]);
   FileClose(fh);
   Print("Exportado: ", filename);
}
