(* Static descriptions contain code as well as data. Their keys retain
   qualified identities and declaration-relative spans, so equal display
   labels in separate modules cannot alias and earlier roots do not rename
   an unchanged description. *)
open Core

let constant ~functions value =
  let parent site (loc : Loc.t) =
    Hashtbl.fold (fun _ (f : fn_def) best ->
      let name=Path.local f.path in
      let contains=f.loc.file=loc.file && f.loc.start.line<=loc.start.line in
      if not contains || not(site=name || String.starts_with ~prefix:(name^".")site)then best
      else match best with
        | None->Some f
        | Some g->
            if f.loc.start.line>g.loc.start.line then Some f else best)
      functions None in
  let location parent (loc : Loc.t) =
    match parent with
    | Some (f : fn_def) when f.loc.file=loc.file ->
        {Loc.file=Path.full f.path;
          start={loc.start with line=loc.start.line-f.loc.start.line+1};
          stop={loc.stop with line=loc.stop.line-f.loc.start.line+1}}
    | _->{loc with file=Filename.basename loc.file}in
  let rec pattern owner (p : pattern) =
    let pat=pattern owner in
    let pkind=match p.pkind with
      | PCon(p,n,ps)->PCon(p,n,List.map pat ps)
      | PTag(n,ps)->PTag(n,List.map pat ps)
      | PTuple ps->PTuple(List.map pat ps)
      | PRecord(p,ps)->PRecord(p,List.map pat ps)
      | POr ps->POr(List.map pat ps)
      | PAs(p,v)->PAs(pat p,v)
      | PArray _ as k->Core.map_seq ~pat ~var:Fun.id k
      | k->k in
    {p with ploc=location owner p.ploc;pkind}
  and code owner (e : expr) =
    let e=Core.map_children(code owner)e in
    let kind=match e.kind with
      | Const c->Const(data c)
      | Match(s,arms)->Match(s,List.map(fun a->{a with pat=pattern owner a.pat})arms)
      | Pattern_scope p->Pattern_scope{p with pat=pattern owner p.pat}
      | k->k in
    {e with kind;loc=location owner e.loc}
  and data (c : constant) =
    let ckind=match c.ckind with
      | CArray xs->CArray(List.map data xs)
      | CTuple xs->CTuple(List.map data xs)
      | CRecord fs->CRecord(List.map(fun(n,c)->n,data c)fs)
      | CCon(p,n,xs)->CCon(p,n,List.map data xs)
      | CTag(n,xs)->CTag(n,List.map data xs)
      | CMap xs->CMap(List.map(fun(k,v)->data k,data v)xs)
      | CSet xs->CSet(List.map data xs)
      | CHandler h->CHandler{h with hbody=code(parent h.hsite h.hbody.loc)h.hbody;
          hcaptures=List.map(fun(v,c)->v,data c)h.hcaptures}
      | k->k in
    {c with ckind}in
  Marshal.to_string(data value)[Marshal.No_sharing]
