//+------------------------------------------------------------------+
//|                                          VWAP_ZScore_EA.mq4      |
//|                    Reversion a la media - Z-score M1             |
//+------------------------------------------------------------------+
//
//  ESTRATEGIA:
//  -----------
//  Detecta drift temporal en series de log returns de velas M1.
//  Estima el modelo estadistico sobre N barras historicas:
//    1. Calcula log returns del VWAP (Open+High+Low+Close)/4
//    2. Busca la escala temporal W optima donde la dispersion de
//       las medias rolling supera lo esperado para ruido blanco puro
//       (ratio sigmamuV/teorico maximo en la curva suavizada)
//    3. Normaliza la media de la ventana actual -> Z-score
//    4. Si |Z| > ZUmbral (configurable por probabilidad) -> senal
//    5. Precio objetivo = distancia restante hasta el umbral
//
//  ENTRADAS:
//  ---------
//  Probabilidad : confianza estadistica deseada (ej: 90%)
//  N            : barras M1 para estimar el modelo (recomendado: 512)
//  Suavizado    : ventana de suavizado del ratio para evitar maximos locales
//  Lots         : tamano de la orden
//  ExecutionThrottle : maximo de trades sin intervencion humana
//
//  GESTION DE RIESGO:
//  ------------------
//  SL = TP = ZUmbral * sigmaPob * W * precio  (simetrico, ratio 1:1)
//  El EA se detiene si se alcanzan ExecutionThrottle trades
//
//  CHANGELOG:
//  ----------
//  v1.0 - 2025-05-19 : version inicial con senal Z-score y W fijo=12
//  v1.1 - 2025-05-19 : W optimo auto-detectado con ratio suavizado
//  v1.2 - 2025-05-19 : precios objetivo y SL/TP basados en distancia Z
//  v1.3 - 2025-05-20 : input Probabilidad reemplaza ZUmbral fijo
//  v1.4 - 2025-05-20 : documentacion y buenas practicas
//  v1.5 - 2026-05-21 : Z y distancias usan sigmaPob en lugar de sigmamuV
//
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Trade App Soft LLC"
#property strict

//--- Fecha de expiracion del EA
datetime fechaVencimiento = D'2027.12.31 00:00';

//=== INPUTS =========================================================
input double Lots              = 0.1;   // Tamano de la orden (lotes)
input int    N                 = 512;   // Barras M1 para estimar el modelo
input int    Wmin              = 15;    // Ventana minima permitida para W optimo
input int    Suavizado         = 5;     // Suavizado del ratio sigmamuV/teorico
input double Probabilidad      = 90.0;  // Confianza estadistica % (80/90/95)
input int    ExecutionThrottle = 200;     // Max trades sin intervencion humana

//=== CONSTANTES =====================================================
#define MAGICMA    20250519   // Identificador unico de ordenes de este EA
#define SLIPPAGE   3          // Slippage maximo en points

//=== VARIABLES GLOBALES - MODELO ESTADISTICO ========================
// Series temporales
double g_dlog[];        // Log returns del VWAP: log(vwap[i]) - log(vwap[i+1])
double g_muVentanas[];  // Medias de cada ventana rolling de tamano g_Woptimo

double g_ratioVec[];    // ratio[w] = sigmamuV(w) / (sigmaPob/sqrt(w))
double g_ratioSuav[];   // Ratio suavizado con promedio movil de Suavizado puntos

// Parametros del modelo (calculados en BuscarWoptimo y EstimarModelo)
double g_sigmaPob;      // Desvio estandar poblacional de los N-1 log returns
double g_sigmamuV;      // Desvio estandar de las medias rolling (escala W optima)
double g_ZUmbral;       // Z correspondiente a la Probabilidad configurada
int    g_Woptimo;       // Escala temporal optima (ventana con ratio maximo)

// Valores de la ultima evaluacion (actualizados en EvaluarSenal)
double g_muActual;      // Media de los ultimos g_Woptimo log returns
double g_Zactual;       // Z-score actual = g_muActual / g_sigmaPob

//=== VARIABLES GLOBALES - TRADING ===================================
bool   g_senalCompra;   // TRUE si Z < -g_ZUmbral (precio cayo demasiado)
bool   g_senalVenta;    // TRUE si Z >  g_ZUmbral (precio subio demasiado)
double g_precioCompra;  // Precio objetivo de entrada para compra
double g_precioVenta;   // Precio objetivo de entrada para venta
int    g_contador;      // Cantidad de trades ejecutados en la sesion
int    g_digitos;       // Decimales del instrumento (ej: 2 para XAUUSD)
double g_distMinBracket;// Distancia minima de SL/TP exigida por el broker

//=== PROTOTIPOS - MODELO ============================================
double CalcMedia(double &arr[], int start, int period);
double CalcDesvio(double &arr[], int start, int period);
void   CalcDlogVwap(double &vwap[], double &dlog[]);
bool   CargarDatos(double &vwap[]);
void   BuscarWoptimo();
void   EstimarModelo();
void   EvaluarSenal();
double NormInv(double p);

//=== PROTOTIPOS - TRADING ===========================================
void   EnviarOrden(int tipo, double precio, double tp, double sl, string comentario, color clr);
bool   activeOrders(string symbol);
void   PrintSenal();

//+------------------------------------------------------------------+
//| OnInit: inicializa el EA y estima el modelo estadistico           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Verificar vigencia del EA
   if (fechaVencimiento < TimeCurrent())
   {
      Alert("EA expirado, contactar TradeAPP");
      ExpertRemove();
      return INIT_FAILED;
   }

   //--- Inicializar variables de trading
   g_digitos        = (int)MarketInfo(Symbol(), MODE_DIGITS);
   g_distMinBracket = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   g_contador       = 0;
   g_senalCompra    = false;
   g_senalVenta     = false;

   //--- Convertir probabilidad a Z umbral usando inversa de la normal
   //    Ej: 90% -> cola bilateral 5% -> p=0.95 -> Z=1.6449
   double prob = Probabilidad / 100.0;
   g_ZUmbral   = NormInv(1.0 - (1.0 - prob) / 2.0);
   Print("Probabilidad=", Probabilidad, "% | Z umbral=", DoubleToString(g_ZUmbral, 4));

   //--- Estimacion inicial del modelo sobre N barras historicas
   double Vwap[];
   if (!CargarDatos(Vwap)) return INIT_FAILED;
   CalcDlogVwap(Vwap, g_dlog);
   BuscarWoptimo();
   EstimarModelo();

   Print("EA inicializado | W optimo=", g_Woptimo,
         " | sigmaPob=", DoubleToString(g_sigmaPob, 8),
         " | sigmamuV=", DoubleToString(g_sigmamuV, 8),
         " | ratio=",    DoubleToString(g_sigmamuV / (g_sigmaPob / MathSqrt(g_Woptimo)), 4));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: logica principal ejecutada en cada tick de precio         |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Verificaciones de seguridad
   if (Bars < 1 || IsTradeAllowed() == false)
   {
      Print("Auto trading deshabilitado");
      ExpertRemove();
      return;
   }

   if (g_contador >= ExecutionThrottle)
   {
      Alert("EA stopeado: alcanzo el maximo de ", ExecutionThrottle, " trades sin intervencion humana");
      ExpertRemove();
      return;
   }

   //--- 2. Nueva vela M1: recalcular modelo completo
   //       Volume[0] <= 1 indica primer tick de la vela actual
   if (Volume[0] <= 1)
   {
      double Vwap[];
      if (!CargarDatos(Vwap)) return;
      CalcDlogVwap(Vwap, g_dlog);
      BuscarWoptimo();   // recalcula W optimo con datos frescos
      EstimarModelo();   // recalcula sigmamuV con nuevo W
      EvaluarSenal();    // calcula Z actual y precios objetivo
      PrintSenal();      // imprime estado en el log (solo en nueva vela)
      return;
   }

   //--- 3. Si hay orden activa del EA, esperar cierre antes de nueva entrada
   if (activeOrders(Symbol())) return;

   //--- 4. Evaluar Z en cada tick con el modelo ya calculado (rapido)
   EvaluarSenal();

   //--- 5. Ejecutar si el precio alcanzo el nivel objetivo
   if (g_senalVenta && Bid >= g_precioVenta)
   {
      double bid  = NormalizeDouble(Bid, g_digitos);
      double dist = g_ZUmbral * g_sigmaPob * g_Woptimo * bid;
      double sl   = NormalizeDouble(bid + dist, g_digitos);
      double tp   = NormalizeDouble(bid - dist, g_digitos);
      EnviarOrden(OP_SELLLIMIT, bid, tp, sl, "Venta Z", Red);
      return;
   }

   if (g_senalCompra && Ask <= g_precioCompra)
   {
      double ask  = NormalizeDouble(Ask, g_digitos);
      double dist = g_ZUmbral * g_sigmaPob * g_Woptimo * ask;
      double sl   = NormalizeDouble(ask - dist, g_digitos);
      double tp   = NormalizeDouble(ask + dist, g_digitos);
      EnviarOrden(OP_BUYLIMIT, ask, tp, sl, "Compra Z", Green);
      return;
   }
}

//+------------------------------------------------------------------+
//| CargarDatos: descarga N velas M1 y calcula VWAP                  |
//| VWAP = (Open + High + Low + Close) / 4                           |
//| Retorna false si no hay suficientes datos                         |
//+------------------------------------------------------------------+
bool CargarDatos(double &vwap[])
{
   double o[], h[], l[], c[];
   if (CopyOpen (_Symbol, PERIOD_M1, 0, N, o) != N ||
       CopyHigh (_Symbol, PERIOD_M1, 0, N, h) != N ||
       CopyLow  (_Symbol, PERIOD_M1, 0, N, l) != N ||
       CopyClose(_Symbol, PERIOD_M1, 0, N, c) != N)
   { Print("Error al cargar datos M1: ", GetLastError()); return false; }

   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   ArrayResize(vwap, N);
   for (int i = 0; i < N; i++)
      vwap[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
   return true;
}

//+------------------------------------------------------------------+
//| BuscarWoptimo: encuentra la escala temporal con mas estructura    |
//|                                                                   |
//| Para cada W de 1 a N/2:                                          |
//|   - Calcula rolling window de medias de tamano W                  |
//|   - ratio[W] = sigmamuV(W) / (sigmaPob/sqrt(W))                  |
//|     ratio > 1: hay mas drift que ruido blanco puro                |
//| Suaviza el ratio con promedio movil para evitar maximos locales   |
//| g_Woptimo = W donde ratio suavizado es maximo                     |
//+------------------------------------------------------------------+
void BuscarWoptimo()
{
   int M    = ArraySize(g_dlog);
   int Wmax = M / 2;

   ArrayResize(g_ratioVec,  Wmax);
   ArrayResize(g_ratioSuav, Wmax);

   g_sigmaPob = CalcDesvio(g_dlog, 0, M);

   for (int w = 1; w <= Wmax; w++)
   {
      int    nV = M - w + 1;
      double muV[];
      ArrayResize(muV, nV);
      for (int i = 0; i < nV; i++)
         muV[i] = CalcMedia(g_dlog, i, w);

      double sigmamuV = CalcDesvio(muV, 0, nV);
      double teorico  = g_sigmaPob / MathSqrt(w);
      g_ratioVec[w-1] = (teorico > 0) ? sigmamuV / teorico : 0;
   }

   //--- Suavizado con promedio movil centrado
   int mitad = Suavizado / 2;
   for (int w = 0; w < Wmax; w++)
   {
      int desde = MathMax(0,    w - mitad);
      int hasta = MathMin(Wmax, w + mitad + 1);
      g_ratioSuav[w] = CalcMedia(g_ratioVec, desde, hasta - desde);
   }

   //--- W optimo = indice del maximo del ratio suavizado, restringido a W >= Wmin
   int wIni    = MathMax(1, Wmin);
   int    idxMax   = wIni - 1;
   double maxRatio = g_ratioSuav[wIni - 1];
   for (int w = wIni; w <= Wmax; w++)
   {
      if (g_ratioSuav[w-1] > maxRatio)
      { maxRatio = g_ratioSuav[w-1]; idxMax = w-1; }
   }
   g_Woptimo = idxMax + 1;
}

//+------------------------------------------------------------------+
//| EstimarModelo: calcula sigmamuV y Zvector con el W optimo         |
//|                                                                   |
//| g_sigmamuV = desvio estandar de las medias de ventanas rolling    |
//|              de tamano g_Woptimo sobre los N-1 log returns        |
//| g_Zvector  = serie normalizada: Z[i] = muVentanas[i] / sigmamuV  |
//+------------------------------------------------------------------+
void EstimarModelo()
{
   int M  = ArraySize(g_dlog);
   int nV = M - g_Woptimo + 1;

   ArrayResize(g_muVentanas, nV);

   for (int i = 0; i < nV; i++)
      g_muVentanas[i] = CalcMedia(g_dlog, i, g_Woptimo);

   g_sigmamuV = CalcDesvio(g_muVentanas, 0, nV);
}

//+------------------------------------------------------------------+
//| EvaluarSenal: calcula Z actual y precios objetivo                 |
//|                                                                   |
//| g_Zactual     = media(ultimos W log returns) * sqrt(W) / sigmaPob |
//| g_precioVenta = Bid + distancia restante hasta Z = +ZUmbral       |
//| g_precioCompra= Ask - distancia restante hasta Z = -ZUmbral       |
//| Distancia (en precio) = deltaZ * sigmaPob * W * precio            |
//| (la distancia en precio usa W, no sqrt(W), para dar SL/TP mas     |
//|  amplios; solo el Z-score de la senal usa sqrt(W))                |
//+------------------------------------------------------------------+
void EvaluarSenal()
{
   g_muActual = CalcMedia(g_dlog, 0, g_Woptimo);
   g_Zactual  = g_muActual * MathSqrt(g_Woptimo) / g_sigmaPob;

   //--- Distancia restante hasta cada umbral, convertida a precio
   double distV   = (g_ZUmbral - g_Zactual) * g_sigmaPob * g_Woptimo * Bid;
   double distC   = (g_ZUmbral + g_Zactual) * g_sigmaPob * g_Woptimo * Ask;
   g_precioVenta  = NormalizeDouble(Bid + distV, g_digitos);
   g_precioCompra = NormalizeDouble(Ask - distC, g_digitos);

   g_senalVenta  = (g_Zactual >  g_ZUmbral);
   g_senalCompra = (g_Zactual < -g_ZUmbral);
}

//+------------------------------------------------------------------+
//| PrintSenal: imprime estado del modelo en el log del EA            |
//|             Llamar solo en nueva vela para no saturar el log      |
//+------------------------------------------------------------------+
void PrintSenal()
{
   //--- SL/TP simetricos basados en la distancia al umbral Z
   double dist = g_ZUmbral * g_sigmaPob * g_Woptimo * Bid;
   double sl_v = NormalizeDouble(g_precioVenta  + dist, g_digitos);
   double tp_v = NormalizeDouble(g_precioVenta  - dist, g_digitos);
   double sl_c = NormalizeDouble(g_precioCompra - dist, g_digitos);
   double tp_c = NormalizeDouble(g_precioCompra + dist, g_digitos);

   string estado = g_senalVenta ? ">>> VENTA " : (g_senalCompra ? ">>> COMPRA" : "Sin senal ");
   double ratio  = g_sigmamuV / (g_sigmaPob / MathSqrt(g_Woptimo));

   Print(estado,
         " | W=",     g_Woptimo,
         " ratio=",   DoubleToString(ratio,          4),
         " Z=",       DoubleToString(g_Zactual,      4),
         " | PV=",    DoubleToString(g_precioVenta,  g_digitos),
         " PC=",      DoubleToString(g_precioCompra, g_digitos),
         " | SL_V=",  DoubleToString(sl_v,           g_digitos),
         " TP_V=",    DoubleToString(tp_v,            g_digitos),
         " SL_C=",    DoubleToString(sl_c,            g_digitos),
         " TP_C=",    DoubleToString(tp_c,            g_digitos));
}

//+------------------------------------------------------------------+
//| EnviarOrden: envia una orden al broker con manejo de errores      |
//+------------------------------------------------------------------+
void EnviarOrden(int tipo, double precio, double tp, double sl, string comentario, color clr)
{
   g_contador++;
   Print("Enviando orden tipo=", tipo, " precio=", precio, " TP=", tp, " SL=", sl);
   int res = OrderSend(Symbol(), tipo, Lots, precio, SLIPPAGE, sl, tp, comentario, MAGICMA, 0, clr);
   if (res == -1)
      Print("Error al enviar orden: ", GetLastError());
   else
      Print("Orden enviada. Ticket=", res, " | Trades acumulados=", g_contador);
}

//+------------------------------------------------------------------+
//| activeOrders: retorna TRUE si hay ordenes activas de este EA      |
//+------------------------------------------------------------------+
bool activeOrders(string symbol)
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if (OrderSymbol() == symbol && OrderMagicNumber() == MAGICMA)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| CalcMedia: media aritmetica de arr[start .. start+period-1]       |
//+------------------------------------------------------------------+
double CalcMedia(double &arr[], int start, int period)
{
   double s = 0;
   for (int i = start; i < start + period; i++) s += arr[i];
   return s / period;
}

//+------------------------------------------------------------------+
//| CalcDesvio: desvio estandar poblacional de arr[start..start+period-1] |
//+------------------------------------------------------------------+
double CalcDesvio(double &arr[], int start, int period)
{
   double m = CalcMedia(arr, start, period), s = 0;
   for (int i = start; i < start + period; i++)
      s += MathPow(arr[i] - m, 2);
   return MathSqrt(s / period);
}

//+------------------------------------------------------------------+
//| CalcDlogVwap: log returns del VWAP                                |
//|   dlog[i] = log(vwap[i]) - log(vwap[i+1])                        |
//|   Serie estacionaria, media ~ 0 para instrumentos no explosivos   |
//+------------------------------------------------------------------+
void CalcDlogVwap(double &vwap[], double &dlog[])
{
   int sz = ArraySize(vwap);
   ArrayResize(dlog, sz - 1);
   for (int i = 0; i < sz - 1; i++)
      dlog[i] = MathLog(vwap[i]) - MathLog(vwap[i+1]);
}

//+------------------------------------------------------------------+
//| NormInv: inversa de la distribucion normal estandar               |
//|          Algoritmo AS241 (Wichura, 1988) — precision ~1e-9        |
//|          Valida para p en (0, 1)                                  |
//|          Ejemplos: NormInv(0.95)=1.6449  NormInv(0.975)=1.9600   |
//+------------------------------------------------------------------+
double NormInv(double p)
{
   if (p <= 0.0 || p >= 1.0) return 0;

   const double a[] = {-3.969683028665376e+01,  2.209460984245205e+02,
                       -2.759285104469687e+02,  1.383577518672690e+02,
                       -3.066479806614716e+01,  2.506628277459239e+00};
   const double b[] = {-5.447609879822406e+01,  1.615858368580409e+02,
                       -1.556989798598866e+02,  6.680131188771972e+01,
                       -1.328068155288572e+01};
   const double c[] = {-7.784894002430293e-03, -3.223964580411365e-01,
                       -2.400758277161838e+00, -2.549732539343734e+00,
                        4.374664141464968e+00,  2.938163982698783e+00};
   const double d[] = { 7.784695709041462e-03,  3.224671290700398e-01,
                        2.445134137142996e+00,  3.754408661907416e+00};

   double q, r, x;
   double pLow  = 0.02425;
   double pHigh = 1.0 - pLow;

   if (p < pLow)
   {
      q = MathSqrt(-2.0 * MathLog(p));
      x = (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
          ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1.0);
   }
   else if (p <= pHigh)
   {
      q = p - 0.5;
      r = q * q;
      x = (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q /
          (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1.0);
   }
   else
   {
      q = MathSqrt(-2.0 * MathLog(1.0 - p));
      x = -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
           ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1.0);
   }
   return x;
}
