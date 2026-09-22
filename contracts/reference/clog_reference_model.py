from math import isqrt, log

BPS=10_000; BUY_TAX=60; SELL_TAX=60
OWNER=4_000; MULTI=1_000; RELEASE=1_111
MS_CLOG=1_000; WP_CLOG=9_000; ITERS=6
CURVE_ALLOC=900_000_000*10**18; CLOG_ALLOC=100_000_000*10**18

def mulDiv(a,b,c): return (a*b)//c

class ClogMarket:
    """Line-for-line port of ClogMarket.sol @ 422a61a (floor integer arithmetic)."""
    def __init__(self, seed, bufferBps):
        self.re=seed; self.rt=mulDiv(CURVE_ALLOC,bufferBps,BPS)
        self.k=self.re*self.rt; self.sold=0; self.realETH=0
        self.hwm=0; self.clogRemaining=CLOG_ALLOC; self.rtCeiling=self.rt
        self.physicalInventory=CURVE_ALLOC+CLOG_ALLOC
        self.virtualEthSeed=seed
        self.owner=0; self.multisig=0; self.winnerPot=0
        self.tgtBps=4_000; self.floorBps=5_000
    def _quoteCurveLeg(self,ethIn):
        newRt=self.k//(self.re+ethIn); out=self.rt-newRt
        ns=self.sold+out
        return out,(ns-self.hwm if ns>self.hwm else 0)
    def _quoteClogLeg(self,curveBudget,curveOut,clogTokens):
        reA=self.re+curveBudget; rtA=self.rt-curveOut
        return self.k//(rtA-clogTokens)-reA
    def _safeExtract(self,netForClog):
        circ=self.rtCeiling-self.rt
        price=0 if self.rt==0 else mulDiv(self.re,10**18,self.rt)
        cv=mulDiv(circ,price,10**18)
        tgt=mulDiv(netForClog,self.tgtBps,BPS)
        if cv==0: ext=tgt
        else:
            after=self.realETH-tgt if self.realETH>=tgt else 0
            if mulDiv(after,BPS,cv)>=self.floorBps: ext=tgt
            else:
                fl=mulDiv(cv,self.floorBps,BPS)
                ext=self.realETH-fl if self.realETH>fl else 0
                if ext>tgt: ext=tgt
        wp=0
        if ext>0:
            tm=mulDiv(ext,MS_CLOG,BPS); wp=ext-tm; self.multisig+=tm
        return ext,netForClog-ext,wp
    def _executeBudget(self,budget):
        cb=budget
        for _ in range(ITERS):
            pOut,pTerr=self._quoteCurveLeg(cb)
            pTgt=min(mulDiv(pTerr,RELEASE,BPS),self.clogRemaining)
            if pTgt==0: break
            pCost=self._quoteClogLeg(cb,pOut,pTgt)
            if pCost>=budget: cb=0; break
            n=budget-pCost
            if n==cb: break
            cb=n
        newRt1=self.k//(self.re+cb); curveTokens=self.rt-newRt1
        self.re+=cb; self.rt=newRt1; self.sold+=curveTokens; self.realETH+=cb
        nt=self.sold-self.hwm if self.sold>self.hwm else 0
        tgtClog=min(mulDiv(nt,RELEASE,BPS),self.clogRemaining)
        clogTokens=ext=ret=wp=0; dust=0
        resid=budget-cb
        if tgtClog>0 and resid>0:
            rtAfter=mulDiv(self.k,1,self.re+resid)
            fromResid=self.rt-rtAfter
            actual=min(fromResid,tgtClog)
            newRt2=self.rt-actual; newRe2=self.k//newRt2
            netForClog=newRe2-self.re
            self.re=newRe2; self.rt=newRt2; self.realETH+=netForClog
            self.clogRemaining-=actual; self.rtCeiling+=actual; self.hwm=self.sold
            clogTokens=actual
            dust=resid-netForClog
            if dust>0: self.re+=dust; self.realETH+=dust
            ext,ret,wp=self._safeExtract(netForClog)
            self.realETH-=ext; self.re-=ext
        self.k=self.re*self.rt
        return curveTokens,clogTokens,ext,wp,dust
    def applyBuy(self,gross):
        tax=mulDiv(gross,BUY_TAX,BPS); budget=gross-tax
        o=mulDiv(tax,OWNER,BPS); m=mulDiv(tax,MULTI,BPS); twp=tax-o-m
        cT,clT,ext,cwp,dust=self._executeBudget(budget)
        out=cT+clT
        assert out<=self.physicalInventory
        self.physicalInventory-=out
        self.owner+=o; self.multisig+=m; self.winnerPot+=twp+cwp
        return out,dust,ext
    def applySell(self,tokensIn):
        newRt=self.rt+tokensIn; ideal=self.re-self.k//newRt
        capped=ideal>self.realETH
        gross=self.realETH if capped else ideal
        self.re-=gross; self.realETH-=gross; self.rt=newRt; self.k=self.re*self.rt
        self.sold=self.sold-tokensIn if self.sold>tokensIn else 0
        self.physicalInventory+=tokensIn
        tax=mulDiv(gross,SELL_TAX,BPS); net=gross-tax
        o=mulDiv(tax,OWNER,BPS); m=mulDiv(tax,MULTI,BPS)
        self.owner+=o; self.multisig+=m; self.winnerPot+=tax-o-m
        return net,capped

class StaticLP:
    """Architecture C: fixed v4 position, k never re-anchored, hook takes tax only."""
    def __init__(self,seed,bufferBps):
        self.re=seed; self.rt=mulDiv(CURVE_ALLOC,bufferBps,BPS)
        self.L2=self.re*self.rt   # STATIC - never re-anchored
        self.realETH=0; self.owner=0; self.multisig=0; self.winnerPot=0
    def buy(self,gross):
        tax=mulDiv(gross,BUY_TAX,BPS); budget=gross-tax
        o=mulDiv(tax,OWNER,BPS); m=mulDiv(tax,MULTI,BPS)
        self.owner+=o; self.multisig+=m; self.winnerPot+=tax-o-m
        newRt=self.L2//(self.re+budget); out=self.rt-newRt
        self.re+=budget; self.rt=newRt; self.realETH+=budget
        return out
