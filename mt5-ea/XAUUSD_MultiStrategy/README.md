# XAUUSD MultiStrategy EA v2.0

Expert Advisor MQL5 multi-stratégie pour XAUUSD (Or) sur timeframe H1.

## Stratégies intégrées

| # | Stratégie | Description |
|---|-----------|-------------|
| 1 | **ORB** | Opening Range Breakout — breakout du range d'ouverture (inspiré GOLD_ORB) |
| 2 | **PA** | Price Action — Pin Bars et Engulfing candles |
| 3 | **MACD** | Croisement MACD Signal avec filtre RSI |
| 4 | **EMA** | Triple EMA (8/21/55) — trend following |

## Installation

1. Copier `XAUUSD_MultiStrategy.mq5` dans `MQL5/Experts/`
2. Ouvrir MetaEditor → compiler (F7)
3. Attacher sur un graphique **XAUUSD H1**
4. Configurer les paramètres (voir ci-dessous)

## Paramètres clés

### Gestion du risque (recommandé)
```
RiskPercent   = 1.0   // 1% du capital par trade
MaxDrawdown   = 15.0  // Stoppe le trading au-delà de 15% de drawdown
MaxPositions  = 3     // Max 3 trades simultanés
UseTrailing   = true  // Trailing stop ATR activé
```

### ATR (Stop Loss / Take Profit)
```
ATR_Period   = 14    // Période standard
SL_ATR_Mult  = 1.5   // SL = 1.5 x ATR
TP_ATR_Mult  = 3.0   // TP = 3.0 x ATR  → ratio R:R = 1:2
Trail_ATR    = 1.0   // Trailing = 1.0 x ATR
```

### ORB (Opening Range Breakout)
```
ORB_Hour    = 9    // Range de 9h à 10h (heure serveur)
ORB_Minutes = 60
ORB_Buffer  = 0.5  // Confirmation = 0.5x ATR au-delà du range
```

### Sessions filtrées
```
Londres : 08h00 — 17h00
New York: 13h00 — 22h00
```

## Architecture du code

```
OnTick()
 ├── IsNewBar()          → exécution H1 uniquement
 ├── CheckDrawdown()     → protection capital
 ├── CheckSession()      → filtre Londres/NY
 ├── ManageTrailingStop()→ trailing dynamique ATR
 ├── GetORBSignal()      → breakout range journalier
 ├── GetPriceActionSignal() → pin bar / engulfing
 ├── GetMACDSignal()     → MACD + RSI
 └── GetEMASignal()      → triple EMA crossover
```

## Backtesting recommandé

- Période : 2020 — présent
- Spread : 30 points (réaliste pour XAUUSD)
- Modèle : Every tick based on real ticks
- Capital initial : 10 000 USD

## Avertissement

Ce logiciel est fourni à des fins éducatives. Le trading sur le Forex/métaux implique des risques significatifs. Testez toujours sur compte démo avant tout déploiement réel.

## Sources d'inspiration

- [GOLD_ORB](https://github.com/) — EA open-source XAUUSD price action H1
- [Geraked/metatrader5](https://github.com/Geraked/metatrader5) — Collection de stratégies MT5
