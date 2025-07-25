# Choi's Full DGA Strategy: RM + CA + DA + DY + IY
# Requirements: quantmod, TTR, PerformanceAnalytics, xts, zoo
rm(list=ls())
library(quantmod)
library(PerformanceAnalytics)
library(xts)
library(zoo)
library(TTR)

# === SETUP ===
start_date <- as.Date("2001-01-01")
equity_tickers <- c("QQQ", "SDY")
defensive_tickers <- c("BIL", "TLT", "^SPGSCI")
canary_ticker <- "TIP"
yield_tickers <- c("^IRX", "^TNX")
dividend_yield_proxy <- "SPY"
benchmark <- "SPY"

all_tickers <- unique(c(equity_tickers, defensive_tickers, canary_ticker, yield_tickers, dividend_yield_proxy, benchmark))
getSymbols(all_tickers, from = start_date)

dividends <- tryCatch(getDividends("SPY", from = start_date), error = function(e) NULL)

# === BUILD INPUTS ===
# Prices
daily_prices <- na.omit(merge(Cl(QQQ), Cl(SDY), Cl(BIL), Cl(TLT), Cl(SPGSCI), Cl(TIP), Cl(SPY)))
colnames(daily_prices) <- c("QQQ", "SDY", "BIL", "TLT", "SPGSCI", "TIP", "SPY")
monthly_prices <- to.monthly(daily_prices, indexAt = "lastof", OHLC = FALSE)

# Returns
monthly_returns <- ROC(monthly_prices, type = "discrete")
monthly_returns <- na.omit(monthly_returns)

# Momentum: average of 1,3,6,9,12 month returns
momentum_score <- function(prices) {
  r1 <- ROC(prices, n = 1, type = "discrete")
  r3 <- ROC(prices, n = 3, type = "discrete")
  r6 <- ROC(prices, n = 6, type = "discrete")
  r9 <- ROC(prices, n = 9, type = "discrete")
  r12 <- ROC(prices, n = 12, type = "discrete")
  avg <- rowMeans(merge(r1, r3, r6, r9, r12), na.rm = TRUE)
  xts(avg, order.by = index(prices))
}

# === SIGNALS ===
# Relative momentum between QQQ and SDY
mom_QQQ <- momentum_score(Cl(to.monthly(QQQ, indexAt = "lastof", OHLC = FALSE)))
mom_SDY <- momentum_score(Cl(to.monthly(SDY, indexAt = "lastof", OHLC = FALSE)))

# Defensive momentum (6-month SMA vs price)
sma6 <- function(x) SMA(x, 6)
sma_signals <- merge(
  Cl(to.monthly(BIL, indexAt = "lastof", OHLC = FALSE)) > sma6(Cl(to.monthly(BIL, indexAt = "lastof", OHLC = FALSE))),
  Cl(to.monthly(TLT, indexAt = "lastof", OHLC = FALSE)) > sma6(Cl(to.monthly(TLT, indexAt = "lastof", OHLC = FALSE))),
  Cl(to.monthly(SPGSCI, indexAt = "lastof", OHLC = FALSE)) > sma6(Cl(to.monthly(SPGSCI, indexAt = "lastof", OHLC = FALSE)))
)
colnames(sma_signals) <- c("BIL", "TLT", "SPGSCI")

# Canary: TIP > 10-month SMA
TIP_monthly <- Cl(to.monthly(TIP, indexAt = "lastof", OHLC = FALSE))
canary_pass <- TIP_monthly > SMA(TIP_monthly, 10)

# Inverted yield curve check 7–15 months ago
IRX_monthly <- Cl(to.monthly(IRX, indexAt = "lastof", OHLC = FALSE)) / 100
TNX_monthly <- Cl(to.monthly(TNX, indexAt = "lastof", OHLC = FALSE)) / 100
yield_spread <- TNX_monthly - IRX_monthly
inversion_flag <- yield_spread < 0
inversion_lagged <- rollapply(inversion_flag, width = 15, FUN = function(x) any(tail(x, 9)), align = "right", fill = NA)

# Dividend yield filter: trailing 12-month SPY dividends / price
if (!is.null(dividends)) {
  # Convert to daily xts to align with SPY prices
  div_daily <- merge(dividends, zoo(, index(SPY)))
  div_daily <- na.fill(div_daily, fill = 0)
  trailing_div <- rollapply(div_daily, width = 252, FUN = sum, align = "right", fill = NA)  # ~12 months of trading days
  price_spy_daily <- Cl(SPY)
  div_yield_xts <- trailing_div / price_spy_daily
  div_yield_xts <- na.omit(div_yield_xts)
  div_yield_ok <- div_yield_xts >= 0.016
} else {
  warning("Dividend data not available; falling back to constant proxy.")
  div_proxy <- Cl(SPY)
  div_yield_xts <- xts(rep(0.0175, length(div_proxy)), order.by = index(div_proxy))
  div_yield_ok <- div_yield_xts >= 0.016
}

# === COMBINE FILTERS ===
signal_dates <- index(mom_QQQ)
weights <- xts(matrix(0, nrow = length(signal_dates), ncol = 5), order.by = signal_dates)
colnames(weights) <- c("QQQ", "SDY", "BIL", "TLT", "SPGSCI")

for (i in 1:length(signal_dates)) {

  dt <- signal_dates[i]
  print(dt)
  if (!(dt %in% index(canary_pass)) || !(dt %in% index(inversion_lagged)) || !(dt %in% index(div_yield_ok)) || !(dt %in% index(sma_signals))) next
  
  risk_on <- canary_pass[dt] & !inversion_lagged[dt] & div_yield_ok[dt]
  
  if (risk_on) {
    best_equity <- ifelse(mom_QQQ[dt] > mom_SDY[dt], "QQQ", "SDY")
    weights[i, best_equity] <- 1
  } else {
    active_def <- sma_signals[dt, ]
    best_def <- names(which.max(ifelse(active_def, mom_QQQ[dt], NA)))  # fallback if needed
    if (!is.na(best_def)) weights[i, best_def] <- 1
  }
}

mom_BIL    <- momentum_score(Cl(to.monthly(BIL,    indexAt="lastof", OHLC=FALSE)))
mom_BIL    <- mom_BIL[complete.cases(mom_BIL),]
mom_TLT    <- momentum_score(Cl(to.monthly(TLT,    indexAt="lastof", OHLC=FALSE)))
mom_SPGSCI <- momentum_score(Cl(to.monthly(SPGSCI, indexAt="lastof", OHLC=FALSE)))
signal_dates <- index(mom_BIL)
weights <- xts(matrix(0, nrow=length(signal_dates), ncol=5), order.by=signal_dates)
colnames(weights) <- c("QQQ","SDY","BIL","TLT","SPGSCI")

for(i in seq_along(signal_dates)) {
  dt <- signal_dates[i]
  print(dt)
  
  # 1) pick the most recent signal at or before dt
  canary_val <- last(canary_pass[index(canary_pass) <= dt])
  inv_val    <- last(inversion_lagged[index(inversion_lagged) <= dt])
  div_val    <- last(div_yield_ok[index(div_yield_ok) <= dt])
  sma_vals   <- last(sma_signals[index(sma_signals) <= dt])
  
  # 2) skip if any are NA or SMA flags missing
  if(any(is.na(c(canary_val, inv_val, div_val))) || length(sma_vals) != ncol(sma_signals)) {
    next
  }
  
  # 3) aggregate the risk-on flag
  risk_on <- canary_val && !inv_val && div_val
  
  if(risk_on) {
    # Offensive: pick QQQ vs SDY
    q_mom <- last(mom_QQQ[index(mom_QQQ) <= dt])
    s_mom <- last(mom_SDY[index(mom_SDY) <= dt])
    best <- if(q_mom > s_mom) "QQQ" else "SDY"
    weights[i, best] <- 1
    
  } else {
    # Defensive: pick among BIL, TLT, SPGSCI
    # 4) Get the most recent defensive momentums as plain numbers
    bil_val    <- as.numeric(last(mom_BIL[index(mom_BIL) <= dt]))
    tlt_val    <- as.numeric(last(mom_TLT[index(mom_TLT) <= dt]))
    spgsci_val <- as.numeric(last(mom_SPGSCI[index(mom_SPGSCI) <= dt]))
    
    def_moms <- c(BIL = bil_val,
                  TLT = tlt_val,
                  SPGSCI = spgsci_val)
    
    # 5) Mask out any that fail their SMA test
    active_flags <- as.logical(last(sma_signals[index(sma_signals) <= dt]))
    def_moms[!active_flags] <- NA
    # mask out any that fail their SMA test
    def_moms[!as.logical(sma_vals)] <- NA
    
    # If *all* defensive MOMs are NA, fall back to BIL
    if (all(is.na(def_moms))) {
      def_moms["BIL"] <- as.numeric(
        last(mom_BIL[index(mom_BIL) <= dt])
      )
    }
    
    best_def <- names(which.max(def_moms))
    if(!is.na(best_def)) weights[i, best_def] <- 1
  }
}




# === RETURNS ===
monthly_returns <- monthly_returns[index(weights), colnames(weights)]
strategy_monthly_returns <- Return.portfolio(monthly_returns, weights = weights)

# Daily returns (map weights)
daily_weights <- na.locf(merge(weights, zoo(, index(daily_prices))))
daily_weights <- daily_weights[index(daily_prices)]
daily_returns <- ROC(daily_prices[, colnames(weights)], type = "discrete")

daily_returns <- daily_returns[index(daily_weights)]

daily_weights <- daily_weights[complete.cases(daily_weights),]
daily_returns <- daily_returns[complete.cases(daily_returns),]

strategy_daily_returns <- Return.portfolio(daily_returns, weights = daily_weights)

bmk <- ROC(daily_prices$SPY)


# Add SPY benchmark
combined_returns <- na.omit(merge(strategy_daily_returns, bmk))
colnames(combined_returns) <- c("Strategy", "SPY")

# === RESULTS ===
charts.PerformanceSummary(combined_returns, main = "Choi DGA: Full Version vs SPY")
Return.annualized(combined_returns)
SharpeRatio.annualized(combined_returns)
