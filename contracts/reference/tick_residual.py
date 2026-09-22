from clog_model import *
from math import sqrt, log, floor
E=10**18
LOG1=log(1.0001)
def tick_of(P): return log(P)/LOG1
def P_of(t): return 1.0001**t

def reanchor(re,rt,x,y,spacing):
    """Derive tick-aligned position for canonical (re,rt) with real reserves (x=ETH,y=token).
       currency0=ETH, currency1=token, P=token/ETH.
       re = x + L/sqrt(Pb);  rt = y + L*sqrt(Pa);  L^2 = re*rt"""
    L=sqrt(re*rt)
    if re-x<=0 or rt-y<=0: return None
    Pb=(L/(re-x))**2
    Pa=((rt-y)/L)**2
    tb=floor(tick_of(Pb)/spacing)*spacing
    ta=floor(tick_of(Pa)/spacing)*spacing
    Pa2,Pb2=P_of(ta),P_of(tb)
    re2=x+L/sqrt(Pb2); rt2=y+L*sqrt(Pa2)
    return (abs(re2-re)/re, abs(rt2-rt)/rt)

print("RE-ANCHOR TICK ERROR after each of 15 buys (0.5 ETH), by tickSpacing")
print(f"{'buy':>4} | " + " | ".join(f"s={s:<3} re_err      rt_err" for s in (1,60,200)))
m=ClogMarket(9*E,20_000)
x=0.0; y=float(CURVE_ALLOC)
for i in range(1,16):
    out,dust,ext=m.applyBuy(E//2)
    budget=(E//2)-mulDiv(E//2,BUY_TAX,BPS)
    x += (budget-ext)/1.0   # ETH retained in position (extraction leaves via flow)
    y -= out
    if y<=0: print(f"  position token exhausted at buy {i}"); break
    row=f"{i:>4} | "
    for s in (1,60,200):
        r=reanchor(float(m.re),float(m.rt),x,y,s)
        row += f"{r[0]:>10.3e} {r[1]:>10.3e} | " if r else "   n/a       n/a    | "
    print(row)

print("\nWORST-CASE re error -> user output error (single trade, 0.5 ETH):")
m2=ClogMarket(9*E,20_000)
base,_,_=m2.applyBuy(E//2)
for s,err in (("1",2.5e-5),("60",1.5e-3),("200",5.0e-3)):
    # perturb re by err, recompute first-buy curve output
    mm=ClogMarket(9*E,20_000); mm.re=int(mm.re*(1+err)); mm.k=mm.re*mm.rt
    o,_,_=mm.applyBuy(E//2)
    print(f"  tickSpacing {s:>3}: re perturbed {err:.1e} -> token output delta {(o-base)/base*100:+.6f}%")
