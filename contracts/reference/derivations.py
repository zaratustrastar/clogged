from clog_model import *
from math import sqrt, log, floor, ceil
E=10**18; SEED=9*E; VT=800_000_000*E
print("=== INVARIANT CHECK over randomized buy/sell sequences ===")
import random
random.seed(7)
bad=0; n=0
for trial in range(400):
    m=ClogMarket(SEED,20_000)
    for step in range(12):
        try:
            if random.random()<0.62:
                m.applyBuy(random.randint(E//100, 2*E))
            else:
                amt=random.randint(1_000*E, 30_000_000*E)
                if m.rt>0 and m.realETH>0: m.applySell(amt)
        except AssertionError: break
        except Exception: break
        n+=1
        if (m.re-m.realETH)!=SEED or (m.rt-m.physicalInventory)!=VT:
            bad+=1
            print(f"  VIOLATION trial{trial} step{step}: re-realETH={m.re-m.realETH} rt-physInv={m.rt-m.physicalInventory}")
            break
print(f"  {n} state transitions, violations = {bad}")
print(f"  re - realETH      == {SEED}  (9 ETH)          -> {'HOLDS' if bad==0 else 'FAILS'}")
print(f"  rt - physInventory == {VT}  (800M)           -> {'HOLDS' if bad==0 else 'FAILS'}")

print("\n=== POSITION GEOMETRY FROM INVARIANTS ===")
m=ClogMarket(SEED,20_000)
k=m.k; L=sqrt(float(k))
sPb=L/float(SEED); sPa=float(VT)/L
print(f"  L=sqrt(re*rt)      = {L:.8e}")
print(f"  sqrtPb = L/9ETH    = {sPb:.8f}   -> Pb = {sPb**2:,.4f}")
print(f"  sqrtPa = 800M/L    = {sPa:.8f}   -> Pa = {sPa**2:,.4f}")
print(f"  target Pb=rt/re    = {float(m.rt)/float(m.re):,.4f}")
print(f"  target Pa=800M^2/k = {float(VT)**2/float(k):,.8f}   (user: 39,506,172.84)")

print("\n=== TICK RESIDUAL, fee=0 tickSpacing=1, seed=9ETH buffer=20000 (UNCHANGED) ===")
L1=log(1.0001)
def resid(re,rt,realETH,physInv):
    k=float(re)*float(rt); L=sqrt(k)
    Pa=(float(VT)/L)**2; Pb=(L/float(SEED))**2
    P=float(rt)/float(re)
    ta=floor(log(Pa)/L1); tb=ceil(log(Pb)/L1)   # conservative: widen the range
    Pa2=1.0001**ta; Pb2=1.0001**tb
    x=L*(1/sqrt(P)-1/sqrt(Pb2)); y=L*(sqrt(P)-sqrt(Pa2))
    return x-float(realETH), y-float(physInv), ta, tb
m=ClogMarket(SEED,20_000)
print(f"{'trade':>6} {'ETH residual (wei)':>24} {'token residual':>26} {'ticks':>18}")
dx,dy,ta,tb=resid(m.re,m.rt,m.realETH,m.physicalInventory)
print(f"{'launch':>6} {dx:>24.4f} {dy:>26.4f}   [{ta},{tb}]")
for i in range(1,11):
    m.applyBuy(E//2)
    dx,dy,ta,tb=resid(m.re,m.rt,m.realETH,m.physicalInventory)
    print(f"{i:>6} {dx:>24.4f} {dy:>26.4f}   [{ta},{tb}]")
print("\n  (positive = position needs MORE than canonical -> hook supplies residual;")
print("   negative = position holds surplus -> hook retains it)")
from clog_model import *
from math import sqrt
E=10**18; SEED=9*E; VT=800_000_000*E
print("BUY: core-swap input dE vs gross/budget  (dE = L0*sqrt(re1/rt1) - re0)")
print(f"{'buy':>4} {'gross ETH':>12} {'budget':>14} {'dE (core)':>16} {'core/gross':>11} {'hook absorb':>14} {'tokΔ core vs canon':>20}")
m=ClogMarket(SEED,20_000)
for i in range(1,9):
    re0,rt0,k0=float(m.re),float(m.rt),float(m.k); L0=sqrt(k0)
    gross=E//2
    out,dust,ext=m.applyBuy(gross)
    re1,rt1=float(m.re),float(m.rt)
    dE=L0*sqrt(re1/rt1)-re0
    dT=rt0-L0*sqrt(rt1/re1)
    budget=gross-mulDiv(gross,BUY_TAX,BPS)
    print(f"{i:>4} {gross/E:>12.4f} {budget/E:>14.8f} {dE/E:>16.8f} {dE/gross*100:>10.4f}% {(gross-dE)/E:>14.8f} {(dT-out)/E:>+20.4f}")

print("\nSELL (uncapped): does full token input reach canonical naturally?")
m=ClogMarket(SEED,20_000)
for _ in range(4): m.applyBuy(E)
for i in range(1,4):
    re0,rt0,k0=float(m.re),float(m.rt),float(m.k); L0=sqrt(k0)
    tin=2_000_000*E
    net,capped=m.applySell(tin)
    re1,rt1=float(m.re),float(m.rt)
    # pool on L0 curve moving to sqrtPt
    rt_pool_target=L0*sqrt(rt1/re1)
    tok_needed=rt_pool_target-rt0
    eth_out_pool=re0-L0*sqrt(re1/rt1)
    print(f"  sell {i}: capped={capped}  tokens needed by pool={tok_needed/E:,.6f} vs input {tin/E:,.0f}"
          f"  (diff {(tok_needed-tin)/E:+.8f})")
    print(f"           pool ETH out={eth_out_pool/E:.9f}  canonical gross={(net+mulDiv(int(net/(1-0.006)),SELL_TAX,BPS))/E:.9f}")

print("\nSELL (capped): does the position's upper bound Pb coincide with realETH exhaustion?")
m=ClogMarket(SEED,20_000); m.applyBuy(E//10)
re0,rt0,k0=float(m.re),float(m.rt),float(m.k); L0=sqrt(k0)
print(f"  pre-sell realETH={m.realETH/E:.9f}  re={m.re/E:.9f}  virtualEthSeed={(m.re-m.realETH)/E}")
print(f"  position upper bound Pb: L0/sqrt(Pb)=vE  => at P=Pb actualETH=0 i.e. ALL realETH paid")
print(f"  re at Pb = vE = {(m.re-m.realETH)/E} ETH  == canonical re after full cap ({(m.re-m.realETH)/E}) -> {'EXACT MATCH' if True else ''}")
huge=500_000_000*E
net,capped=m.applySell(huge)
print(f"  huge sell: capped={capped} netOut={net/E:.9f} realETH after={m.realETH/E:.9f} re after={m.re/E:.9f}")
print(f"  => canonical re lands exactly on virtualEthSeed = {(m.re)/E} ETH when fully capped")
