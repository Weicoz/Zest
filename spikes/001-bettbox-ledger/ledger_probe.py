import json,re,sys,time,urllib.request,os
cfg=open(os.path.expanduser('~/Library/Application Support/com.appshub.bettbox/config.yaml')).read()
secret=re.search(r'^secret:\s*["\']?([^"\'\n]*)',cfg,re.M).group(1)
def get():
    r=urllib.request.Request('http://127.0.0.1:9090/connections',headers={'Authorization':'Bearer '+secret})
    return json.load(urllib.request.urlopen(r,timeout=5))
interval=float(sys.argv[1]); dur=float(sys.argv[2])
prev=get(); seen={c['id']:(c['download'],c['upload']) for c in prev['connections'] if c['metadata'].get('type','').lower()!='inner'}
t0=time.time(); sd=su=0; closed=newc=0; contrib={}
while time.time()-t0<dur:
    time.sleep(interval); cur=get(); ids={}
    for c in cur['connections']:
        if c['metadata'].get('type','').lower()=='inner': continue
        d,u=seen.get(c['id'],(0,0))
        if c['id'] not in seen: newc+=1
        sd+=max(0,c['download']-d); su+=max(0,c['upload']-u); m=c['metadata']; k=(m.get('process'),m.get('host') or m.get('destinationIP'),tuple(c['chains']),c['id'] in seen or 'NEW'); contrib[k]=contrib.get(k,0)+max(0,c['upload']-u); ids[c['id']]=(c['download'],c['upload'])
    closed+=len(set(seen)-set(ids)); seen=ids; last=cur
td=last['downloadTotal']-prev['downloadTotal']; tu=last['uploadTotal']-prev['uploadTotal']
pct=lambda a,b: round(100*a/b,1) if b else None
print(f"interval={interval}s dur={dur}s new={newc} closed={closed} ledger_down={sd} total_down={td} cover_down={pct(sd,td)}% ledger_up={su} total_up={tu} cover_up={pct(su,tu)}%")
for k,v in sorted(contrib.items(),key=lambda x:-x[1])[:5]: print(v,k[0],k[2],k[3])
