import numpy as np, json, coremltools as ct, ml_dtypes
from coremltools.converters.mil import Builder as mb
from huggingface_hub import hf_hub_download
def load():
    p=hf_hub_download("HuggingFaceTB/SmolLM2-135M","model.safetensors");raw=open(p,'rb').read()
    hlen=int.from_bytes(raw[:8],'little');hdr=json.loads(raw[8:8+hlen]);base=8+hlen
    D={'F32':np.float32,'F16':np.float16,'BF16':ml_dtypes.bfloat16};Wd={}
    for k,m in hdr.items():
        if k=='__metadata__':continue
        dt=D[m['dtype']];b,e=m['data_offsets']
        a=np.frombuffer(raw,dtype=dt,offset=base+b,count=(e-b)//np.dtype(dt).itemsize)
        Wd[k]=a.reshape(m['shape']).astype(np.float32)
    return Wd
W=load();dim,nh,nkv,hd,eps,theta,NL,V=576,9,3,64,1e-5,10000.0,30,49152
EMB=W["model.embed_tokens.weight"]
S=8
pos=np.arange(S)[:,None];i=np.arange(0,hd,2)[None,:];ang=pos*(1.0/(theta**(i/hd)))
COS=np.cos(ang).astype(np.float32);SIN=np.sin(ang).astype(np.float32);MASK=np.triu(np.full((S,S),-1e9,np.float32),1)
# ---- numpy full forward ----
def rms(x,w):return x/np.sqrt((x*x).mean(-1,keepdims=True)+eps)*w
def ropen(x):
    x1=x[...,0::2];x2=x[...,1::2];o=np.empty_like(x)
    o[...,0::2]=x1*COS[:,None,:]-x2*SIN[:,None,:];o[...,1::2]=x1*SIN[:,None,:]+x2*COS[:,None,:];return o
def npfwd(ids):
    x=EMB[ids].copy()
    for L in range(NL):
        def g(n):return W[f"model.layers.{L}.{n}"]
        h=rms(x,g("input_layernorm.weight"))
        q=(h@g("self_attn.q_proj.weight").T).reshape(S,nh,hd);k=(h@g("self_attn.k_proj.weight").T).reshape(S,nkv,hd);v=(h@g("self_attn.v_proj.weight").T).reshape(S,nkv,hd)
        q=ropen(q);k=ropen(k);k=np.repeat(k,nh//nkv,1);v=np.repeat(v,nh//nkv,1)
        o=np.zeros((S,nh,hd))
        for hh in range(nh):
            sc=q[:,hh]@k[:,hh].T/np.sqrt(hd)+MASK;sc=np.exp(sc-sc.max(-1,keepdims=True));sc/=sc.sum(-1,keepdims=True);o[:,hh]=sc@v[:,hh]
        x=x+o.reshape(S,dim)@g("self_attn.o_proj.weight").T
        h=rms(x,g("post_attention_layernorm.weight"))
        gt=h@g("mlp.gate_proj.weight").T;up=h@g("mlp.up_proj.weight").T;x=x+((gt/(1+np.exp(-gt)))*up)@g("mlp.down_proj.weight").T
    x=rms(x,W["model.norm.weight"]);return x@EMB.T
ids=np.array([1,338,460,257,1175,8,9,10],dtype=np.int64)
ref=npfwd(ids);print("numpy argmax last:",int(ref[-1].argmax()))
# ---- MIL full ----
def rmsn(x,w):
    ms=mb.reduce_mean(x=mb.mul(x=x,y=x),axes=[-1],keep_dims=True)
    return mb.mul(x=mb.mul(x=x,y=mb.rsqrt(x=mb.add(x=ms,y=eps))),y=w)
def ropem(t,nheads):
    h2=hd//2;t4=mb.reshape(x=t,shape=[S,nheads,h2,2])
    x1=mb.reshape(x=mb.slice_by_index(x=t4,begin=[0,0,0,0],end=[S,nheads,h2,1]),shape=[S,nheads,h2])
    x2=mb.reshape(x=mb.slice_by_index(x=t4,begin=[0,0,0,1],end=[S,nheads,h2,2]),shape=[S,nheads,h2])
    cs=mb.reshape(x=mb.const(val=COS),shape=[S,1,h2]);sn=mb.reshape(x=mb.const(val=SIN),shape=[S,1,h2])
    o1=mb.sub(x=mb.mul(x=x1,y=cs),y=mb.mul(x=x2,y=sn));o2=mb.add(x=mb.mul(x=x1,y=sn),y=mb.mul(x=x2,y=cs))
    return mb.reshape(x=mb.concat(values=[mb.reshape(x=o1,shape=[S,nheads,h2,1]),mb.reshape(x=o2,shape=[S,nheads,h2,1])],axis=3),shape=[S,nheads,hd])
@mb.program(input_specs=[mb.TensorSpec(shape=(S,dim))])
def prog(x):
    rep=nh//nkv
    for L in range(NL):
        def g(n):return W[f"model.layers.{L}.{n}"]
        h=rmsn(x,g("input_layernorm.weight").reshape(1,dim))
        q=ropem(mb.reshape(x=mb.matmul(x=h,y=g("self_attn.q_proj.weight"),transpose_y=True),shape=[S,nh,hd]),nh)
        k=ropem(mb.reshape(x=mb.matmul(x=h,y=g("self_attn.k_proj.weight"),transpose_y=True),shape=[S,nkv,hd]),nkv)
        v=mb.reshape(x=mb.matmul(x=h,y=g("self_attn.v_proj.weight"),transpose_y=True),shape=[S,nkv,hd])
        k=mb.reshape(x=mb.tile(x=mb.reshape(x=k,shape=[S,nkv,1,hd]),reps=[1,1,rep,1]),shape=[S,nh,hd])
        v=mb.reshape(x=mb.tile(x=mb.reshape(x=v,shape=[S,nkv,1,hd]),reps=[1,1,rep,1]),shape=[S,nh,hd])
        qh=mb.transpose(x=q,perm=[1,0,2]);kh=mb.transpose(x=k,perm=[1,0,2]);vh=mb.transpose(x=v,perm=[1,0,2])
        sc=mb.add(x=mb.mul(x=mb.matmul(x=qh,y=kh,transpose_y=True),y=1.0/np.sqrt(hd)),y=mb.reshape(x=mb.const(val=MASK),shape=[1,S,S]))
        o=mb.matmul(x=mb.softmax(x=sc,axis=-1),y=vh)
        o=mb.reshape(x=mb.transpose(x=o,perm=[1,0,2]),shape=[S,dim])
        x=mb.add(x=x,y=mb.matmul(x=o,y=g("self_attn.o_proj.weight"),transpose_y=True))
        h=rmsn(x,g("post_attention_layernorm.weight").reshape(1,dim))
        gt=mb.matmul(x=h,y=g("mlp.gate_proj.weight"),transpose_y=True);up=mb.matmul(x=h,y=g("mlp.up_proj.weight"),transpose_y=True)
        x=mb.add(x=x,y=mb.matmul(x=mb.mul(x=mb.mul(x=gt,y=mb.sigmoid(x=gt)),y=up),y=g("mlp.down_proj.weight"),transpose_y=True))
    x=rmsn(x,W["model.norm.weight"].reshape(1,dim))
    return mb.matmul(x=x,y=EMB,transpose_y=True,name="logits")
m=ct.convert(prog,convert_to="mlprogram",compute_units=ct.ComputeUnit.CPU_AND_NE)
emb_in=EMB[ids].astype(np.float32)
lg=m.predict({"x":emb_in})["logits"]
print("ANE argmax last:",int(lg[-1].argmax()),"| match:",int(lg[-1].argmax())==int(ref[-1].argmax()))
print("logit maxerr:",round(float(np.abs(lg-ref).max()),3))
m.save("/tmp/smollm2_135m.mlpackage");print("saved full model mlpackage")
