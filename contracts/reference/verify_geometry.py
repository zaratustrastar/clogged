from clog_model import *
from math import isqrt, log, sqrt
E=10**18
seed=9*E; buf=20_000
re0=seed; rt0=mulDiv(CURVE_ALLOC,buf,BPS); Q=CURVE_ALLOC
k=re0*rt0
print("=== LAUNCH PARAMS ===")
print(f"re0 (virtualEthSeed) = {re0/E:,.4f} ETH")
print(f"rt0 (buffered)       = {rt0/E:,.0f} tokens   (= 900M x {buf/BPS})")
print(f"Q   (deposit)        = {Q/E:,.0f} tokens")
print(f"k = re0*rt0          = {k:.6e}")
# CANDIDATE IDENTITIES (user's)
L  = isqrt(k)
Pb = rt0/re0
Pa = (rt0-Q)**2/(re0*rt0)
print("\n=== CANDIDATE IDENTITIES ===")
print(f"L  = sqrt(re0*rt0)      = {L:.6e}")
print(f"Pb = rt0/re0            = {Pb:,.4f} token/ETH")
print(f"Pa = (rt0-Q)^2/(re0rt0) = {Pa:,.4f} token/ETH")
print(f"Pb/Pa                   = {Pb/Pa:.6f}   (expect (rt0/(rt0-Q))^2 = {(rt0/(rt0-Q))**2:.6f})")
# RECONSTRUCT reserves from geometry, currency0=ETH, currency1=token, P=token/ETH
# launch at UPPER bound P=Pb  =>  actualETH x = 0
sPa, sPb, sP = sqrt(Pa), sqrt(Pb), sqrt(Pb)
x = L*(1/sP - 1/sPb)        # ETH (currency0)
y = L*(sP - sPa)            # token (currency1)
re_chk = x + L/sPb
rt_chk = y + L*sPa
print("\n=== RECONSTRUCTION AT LAUNCH (P = Pb) ===")
print(f"actualETH   x          = {x:.6e}      (expect 0)")
print(f"actualToken y          = {y/E:,.4f}  (expect {Q/E:,.0f})   err={abs(y-Q)/Q:.3e}")
print(f"re = x + L/sqrt(Pb)    = {re_chk/E:,.6f} ETH  (expect {re0/E})  err={abs(re_chk-re0)/re0:.3e}")
print(f"rt = y + L*sqrt(Pa)    = {rt_chk/E:,.2f}     (expect {rt0/E:,.0f}) err={abs(rt_chk-rt0)/rt0:.3e}")
print(f"re*rt                  = {re_chk*rt_chk:.6e}  vs L^2 = {L*L:.6e}")
# exhaustion check: at P=Pa all Q sold
y_at_Pa = L*(sPa-sPa)
rt_at_Pa = 0 + L*sPa
print("\n=== AT LOWER BOUND P = Pa (curve exhausted) ===")
print(f"actualToken            = {y_at_Pa:.3e}  (expect 0)")
print(f"rt                     = {rt_at_Pa/E:,.2f}  (expect rt0-Q = {(rt0-Q)/E:,.0f})")
print(f"=> tokens delivered    = {(rt0-rt_at_Pa)/E:,.2f}  (expect Q = {Q/E:,.0f})")
# ticks
t=lambda P: log(P)/log(1.0001)
print("\n=== TICKS (18/18 decimals, raw==human) ===")
print(f"tick(Pa) = {t(Pa):,.1f}   tick(Pb) = {t(Pb):,.1f}   width = {t(Pb)-t(Pa):,.1f}")
print(f"Klik for comparison: tickLower=-887,200  tickUpper=184,200  init=184,216")
print(f"Klik L*sqrt(Pa) = {100080116203748168163562*sqrt(1.0001**-887200)/E:.3e} tokens -> bufferBps ~ 10000 (no token-side buffer)")
