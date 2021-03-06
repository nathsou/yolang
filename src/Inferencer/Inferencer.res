open Belt
open Core
open Types
open Subst
open Unification

let constTy = (c: Ast.Const.t): polyTy => {
  let ty = switch c {
  | Ast.Const.U8Const(_) => u8Ty
  | Ast.Const.U32Const(_) => u32Ty
  | Ast.Const.BoolConst(_) => boolTy
  | Ast.Const.CharConst(_) => charTy
  | Ast.Const.StringConst(_) => stringTy
  | Ast.Const.UnitConst => unitTy
  }

  polyOf(ty)
}

let binOpTy = (op: Ast.BinOp.t): polyTy => {
  open Ast.BinOp
  switch op {
  | Plus => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | Sub => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | Mult => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | Div => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | Mod => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | Equ => ([0], funTy([TyVar(0), TyVar(0)], boolTy)) // (a, a) -> bool
  | Neq => ([0], funTy([TyVar(0), TyVar(0)], boolTy)) // (a, a) -> bool
  | Lss => polyOf(funTy([u32Ty, u32Ty], boolTy))
  | Leq => polyOf(funTy([u32Ty, u32Ty], boolTy))
  | Gtr => polyOf(funTy([u32Ty, u32Ty], boolTy))
  | Geq => polyOf(funTy([u32Ty, u32Ty], boolTy))
  | LogicalAnd => polyOf(funTy([boolTy, boolTy], boolTy))
  | LogicalOr => polyOf(funTy([boolTy, boolTy], boolTy))
  | BitwiseAnd => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | BitwiseOr => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | ShiftLeft => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  | ShiftRight => polyOf(funTy([u32Ty, u32Ty], u32Ty))
  }
}

let unaryOpTy = (op: Ast.UnaryOp.t): polyTy => {
  open Ast.UnaryOp
  switch op {
  | Neg => polyOf(funTy([u32Ty], u32Ty))
  | Not => polyOf(funTy([boolTy], boolTy))
  | Deref => ([0], funTy([pointerTy(TyVar(0))], TyVar(0))) // Ptr<a> -> a
  }
}

// keep a stack of return types of functions to correctly infer the types for
// function bodies using 'return' expressions
let funcRetTyStack: MutableStack.t<monoTy> = MutableStack.make()

let rec collectFuncTypeSubstsWith = (
  env: Env.t,
  args: array<Name.nameRef>,
  body,
  tau,
  funcName: option<string>,
) => {
  let tauRet = CoreExpr.typeOf(body)
  funcRetTyStack->MutableStack.push(tauRet)

  let gammaArgs =
    args->Array.reduce(env, (acc, x) => acc->Env.addMono(x.contents.name, x.contents.ty))

  let fTy = funTy(args->Array.map(x => x.contents.ty), tauRet)

  let gammaFArgs = switch funcName {
  | Some(f) => gammaArgs->Env.addMono(f, fTy)
  | None => gammaArgs
  }

  collectCoreExprTypeSubstsWith(gammaFArgs, body, tauRet)->Result.flatMap(sig => {
    let sigFty = substMono(sig, fTy)
    let sigTau = substMono(sig, tau)
    let sigGamma = substEnv(sig, env)
    let sigFtyGen = generalizeTy(sigGamma, sigFty)
    unify(sigTau, sigFty)->Result.map(sig2 => {
      let _ = funcRetTyStack->MutableStack.pop
      let sig21 = substCompose(sig2, sig)

      (sig21, sig2->substMono(sigTau), sig2->substPoly(sigFtyGen))
    })
  })
}

and collectCoreExprTypeSubstsWith = (env: Env.t, expr: CoreExpr.t, tau: monoTy): result<
  Subst.t,
  string,
> => {
  collectCoreExprTypeSubsts(env, expr)->Result.flatMap(sig => {
    unify(substMono(sig, tau), substMono(sig, CoreExpr.typeOf(expr)))->Result.map(sig2 =>
      substCompose(sig2, sig)
    )
  })
}

and collectCoreExprTypeSubsts = (env: Env.t, expr: CoreExpr.t): result<Subst.t, string> => {
  open Result

  switch expr {
  | CoreConstExpr(c) =>
    let tau' = Context.freshInstance(constTy(c))
    unify(expr->CoreExpr.typeOf, tau')
  | CoreVarExpr(x) => {
      let x = x.contents
      switch env->Env.get(x.name) {
      | Some(ty) => unify(x.ty, Context.freshInstance(ty))
      | None =>
        switch Context.getStruct(x.name) {
        | Some(s) => {
            let staticFuncs = TyStruct(
              PartialStruct(
                Types.Attributes.fromArray(
                  s.staticFuncs->Array.map(({name}) => (name.contents.name, name.contents.ty)),
                  Context.freshTyVarIndex(),
                ),
              ),
            )

            unify(x.ty, staticFuncs)
          }
        | None => Error(`unbound variable: "${x.name}"`)
        }
      }
    }
  | CoreAssignmentExpr(lhs, rhs) => {
      let tau1 = lhs->CoreAst.typeOfExpr
      let tau2 = rhs->CoreAst.typeOfExpr
      collectCoreExprTypeSubsts(env, rhs)->flatMap(sig1 => {
        let sig1Gamma = substEnv(sig1, env)
        let sig1Tau1 = substMono(sig1, tau1)
        collectCoreExprTypeSubstsWith(sig1Gamma, lhs, sig1Tau1)->flatMap(sig2 => {
          let sig21 = substCompose(sig2, sig1)
          let sig21Tau1 = substMono(sig2, sig1Tau1)
          let sig21Tau2 = substMono(sig21, tau2)
          unify(sig21Tau1, sig21Tau2)->map(sig3 => substCompose(sig3, sig21))
        })
      })
    }
  | CoreUnaryOpExpr(tau, op, expr) => {
      let tau1 = CoreExpr.typeOf(expr)
      collectCoreExprTypeSubsts(env, expr)->flatMap(sig => {
        let sigOpTy = substMono(sig, funTy([tau1], tau))
        let tau' = Context.freshInstance(unaryOpTy(op))
        unify(sigOpTy, tau')->map(sig2 => substCompose(sig2, sig))
      })
    }
  | CoreBinOpExpr(tau, a, op, b) =>
    collectCoreExprTypeSubsts(env, a)->flatMap(sigA => {
      let sigAGamma = substEnv(sigA, env)
      collectCoreExprTypeSubsts(sigAGamma, b)->flatMap(sigB => {
        let sigBA = substCompose(sigB, sigA)
        let opTy = substMono(sigBA, funTy([CoreExpr.typeOf(a), CoreExpr.typeOf(b)], tau))
        let tau' = Context.freshInstance(binOpTy(op))
        unify(opTy, tau')->map(sig => substCompose(sig, sigBA))
      })
    })
  | CoreBlockExpr(tau, stmts, lastExpr, _) => {
      open Array

      stmts
      ->reduce(Ok(Map.Int.empty, env), (acc, e) => {
        acc->flatMap(((sig, env)) => {
          collectCoreStmtTypeSubsts(env, e)->Result.map(sig2 => {
            (substCompose(sig2, sig), substEnv(sig2, env))
          })
        })
      })
      ->Result.flatMap(((sig, _)) => {
        switch lastExpr {
        | Some(expr) =>
          collectCoreExprTypeSubsts(substEnv(sig, env), expr)->Result.flatMap(sig2 => {
            let retTy = CoreExpr.typeOf(expr)
            let sig21 = substCompose(sig2, sig)
            unify(substMono(sig21, tau), substMono(sig21, retTy))->Result.map(sig3 =>
              substCompose(sig3, sig21)
            )
          })
        | None => unify(substMono(sig, tau), unitTy)->Result.map(sig2 => substCompose(sig2, sig))
        }
      })
    }
  | CoreLetInExpr(tau, _mut, x, e1, e2) => {
      let x = x.contents
      let tau1 = CoreExpr.typeOf(e1)
      collectCoreExprTypeSubsts(env, e1)->flatMap(sig1 => {
        let sig1Gamma = substEnv(sig1, env)
        let sig1Tau1 = substMono(sig1, tau1)
        let sig1Tau = substMono(sig1, tau)
        let sig1Tau1Gen = generalizeTy(sig1Gamma->Env.remove(x.name), sig1Tau1)
        let gammaX = sig1Gamma->Env.add(x.name, sig1Tau1Gen)
        collectCoreExprTypeSubstsWith(gammaX, e2, sig1Tau)->flatMap(sig2 => {
          let sig21 = substCompose(sig2, sig1)
          unify(substMono(sig21, tau1), substMono(sig21, x.ty))->map(sig3 =>
            substCompose(sig3, sig21)
          )
        })
      })
    }
  | CoreLetRecInExpr(tau, f, args, body, inExpr) => {
      let f = f.contents
      let tauBody = CoreExpr.typeOf(body)

      funcRetTyStack->MutableStack.push(tauBody)

      let fTy = funTy(args->Array.map(x => x.contents.ty), tauBody)

      let gammaArgs =
        args->Array.reduce(env, (acc, x) => acc->Env.addMono(x.contents.name, x.contents.ty))
      let gammaFX = gammaArgs->Env.addMono(f.name, fTy)

      collectCoreExprTypeSubstsWith(gammaFX, body, tauBody)->flatMap(sig1 => {
        let sig1Gamma = sig1->substEnv(gammaFX)
        let sig1FTy = sig1->substMono(fTy)
        let sig1Tau = sig1->substMono(tau)
        let gammaFGen = sig1Gamma->Env.add(f.name, sig1Gamma->generalizeTy(sig1FTy))
        collectCoreExprTypeSubstsWith(gammaFGen, inExpr, sig1Tau)->flatMap(sig2 => {
          let sig21 = substCompose(sig2, sig1)

          unify(f.ty, substMono(sig2, sig1FTy))->map(sig3 => {
            let _ = funcRetTyStack->MutableStack.pop
            substCompose(sig3, sig21)
          })
        })
      })
    }
  | CoreIfExpr(tau, e1, e2, e3) =>
    collectCoreExprTypeSubstsWith(env, e1, boolTy)->flatMap(sig1 => {
      let sig1Gamma = substEnv(sig1, env)
      let sig1Tau = substMono(sig1, tau)
      collectCoreExprTypeSubstsWith(sig1Gamma, e2, sig1Tau)->flatMap(sig2 => {
        let sig21Gamma = substEnv(sig2, sig1Gamma)
        let sig21Tau = substMono(sig2, sig1Tau)
        let sig21 = substCompose(sig2, sig1)
        collectCoreExprTypeSubstsWith(sig21Gamma, e3, sig21Tau)->map(sig3 => {
          substCompose(sig3, sig21)
        })
      })
    })

  | CoreFuncExpr(tau, args, body) =>
    collectFuncTypeSubstsWith(env, args, body, tau, None)->map(((sig, _, _)) => sig)
  | CoreAppExpr(tau, lhs, args) => {
      let argsTy = args->Array.map(CoreExpr.typeOf)
      let fTy = funTy(argsTy, tau)

      collectCoreExprTypeSubstsWith(env, lhs, fTy)
      ->flatMap(sig1 => {
        args
        ->Array.zip(argsTy)
        ->Array.reduce(Ok((sig1, substEnv(sig1, env))), (acc, (arg, argTy)) => {
          acc->flatMap(((sign, signGamma)) => {
            let signArgTy = substMono(sign, argTy)
            collectCoreExprTypeSubstsWith(signGamma, arg, signArgTy)->map(sig2 => {
              (substCompose(sig2, sign), substEnv(sig2, signGamma))
            })
          })
        })
      })
      ->map(((sig, _)) => sig)
    }
  | CoreWhileExpr(cond, body) => {
      let tauBody = CoreExpr.typeOf(body)
      collectCoreExprTypeSubsts(env, cond)->flatMap(sig1 => {
        let sig1TauBody = substMono(sig1, tauBody)
        let sig1Gamma = substEnv(sig1, env)
        collectCoreExprTypeSubstsWith(sig1Gamma, body, sig1TauBody)->map(sig2 =>
          substCompose(sig2, sig1)
        )
      })
    }
  | CoreReturnExpr(ret) =>
    switch funcRetTyStack->MutableStack.top {
    | Some(funcRetTy) =>
      collectCoreExprTypeSubstsWith(
        env,
        ret->Option.mapWithDefault(Core.CoreAst.CoreConstExpr(Ast.Const.UnitConst), x => x),
        funcRetTy,
      )
    | None => Error("'return' used outside of a function")
    }
  | CoreTypeAssertionExpr(expr, originalTy, _assertedTy) =>
    collectCoreExprTypeSubstsWith(env, expr, originalTy)
  | CoreTupleExpr(exprs) => {
      let res = exprs->Array.reduce(Ok((Subst.empty, env)), (prev, exprN) => {
        prev->flatMap(((sigN, gammaN)) => {
          collectCoreExprTypeSubsts(gammaN, exprN)->flatMap(sig => {
            let nextSig = substCompose(sig, sigN)
            let nextGamma = substEnv(sig, gammaN)
            Ok((nextSig, nextGamma))
          })
        })
      })

      res->map(((sig, _)) => sig)
    }
  | CoreStructExpr(name, attrs) =>
    switch Context.getStruct(name) {
    | Some({attributes}) => {
        let res =
          attributes
          ->Array.keep(({impl}) => impl->Option.isNone)
          ->Array.reduce(Ok((env, Subst.empty)), (acc, {name: attrName, ty: attrTy}) => {
            acc->flatMap(((gammaN, sigN)) => {
              switch attrs->Array.getBy(((n, _)) => n == attrName) {
              | None => Error(`missing attribute "${attrName}" for struct "${name}"`)
              | Some((_, val)) =>
                collectCoreExprTypeSubstsWith(gammaN, val, attrTy)->flatMap(sig => {
                  let gammaN' = substEnv(sig, gammaN)
                  let sig' = substCompose(sig, sigN)
                  Ok((gammaN', sig'))
                })
              }
            })
          })

        // check that there are no extraneous attributes
        let extraAttr = attrs->Utils.Array.firstSomeBy(((attrName, _)) =>
          if attributes->Array.some(attr => attr.name == attrName) {
            None
          } else {
            Some(attrName)
          }
        )

        switch extraAttr {
        | Some(extraAttrName) =>
          Error(`extraneous attribute: "${extraAttrName}" for struct "${name}"`)
        | None => res->map(((_, sig)) => sig)
        }
      }

    | None => Error(`undeclared struct "${name}"`)
    }
  | CoreArrayExpr(tau, init) => {
      let elemTy = Context.freshTyVar()
      let sig1 = switch init {
      | CoreAst.ArrayInitRepeat(x, _) => collectCoreExprTypeSubstsWith(env, x, elemTy)
      | CoreAst.ArrayInitList(elems) => {
          let res = elems->Array.reduce(Ok((Subst.empty, env)), (prev, elemN) => {
            prev->flatMap(((sigN, gammaN)) => {
              let sigNElemTy = substMono(sigN, elemTy)
              collectCoreExprTypeSubstsWith(gammaN, elemN, sigNElemTy)->flatMap(sig => {
                let nextSig = substCompose(sig, sigN)
                let nextGamma = substEnv(sig, gammaN)

                Ok((nextSig, nextGamma))
              })
            })
          })

          res->map(((sig, _)) => sig)
        }
      }

      let len = init->CoreAst.ArrayInit.len

      sig1->flatMap(sig1 => {
        unify(tau, arrayTy(elemTy, len))->map(sig2 => {
          substCompose(sig2, sig1)
        })
      })
    }
  | CoreAttributeAccessExpr(tau, lhs, attr) =>
    collectCoreExprTypeSubsts(env, lhs)->flatMap(sig1 => {
      let lhsTy = lhs->CoreAst.typeOfExpr
      let sig1LhsTy = substMono(sig1, lhsTy)

      // when the lhs's type is not a struct during the first pass
      let reCheck = sig => {
        if sig1LhsTy != substMono(sig, lhsTy) {
          collectCoreExprTypeSubstsWith(substEnv(sig, env), expr, substMono(sig, tau))
        } else {
          Ok(sig)
        }
      }

      switch sig1LhsTy {
      | TyStruct(structTy) =>
        switch structTy {
        | NamedStruct(name) =>
          switch Context.getStruct(name) {
          | Some({attributes}) =>
            switch attributes->Array.getBy(({name}) => name === attr) {
            | Some({ty: attrTy, impl}) => {
                let attrTy = impl->Option.mapWithDefault(attrTy, ((f, _)) => f.contents.ty)

                unify(substMono(sig1, tau), substMono(sig1, attrTy))->map(sig2 =>
                  substCompose(sig2, sig1)
                )
              }
            | None => Error(`attribute "${attr}" does not exist on struct "${name}"`)
            }
          | None => Error(`undeclared struct: "${name}"`)
          }
        | PartialStruct(attrs) =>
          switch attrs->Attributes.toMap->Map.String.get(attr) {
          | Some(attrTy) =>
            unify(substMono(sig1, tau), substMono(sig1, attrTy))->map(sig2 =>
              substCompose(sig2, sig1)
            )
          | None => {
              open StructMatching

              // extend this partial struct with this attribute
              let extendedAttrs = attrs->Attributes.insert(attr, tau)
              let extendedStructTy = substMono(sig1, TyStruct(PartialStruct(extendedAttrs)))

              switch findMatchingStruct(extendedAttrs) {
              | OneMatch(matchingStruct) =>
                unify(sig1LhsTy, TyStruct(NamedStruct(matchingStruct.name)))->flatMap(sig2 => {
                  let sig21 = substCompose(sig2, sig1)
                  reCheck(sig21)
                })
              | MultipleMatches(_) =>
                unify(sig1LhsTy, extendedStructTy)->flatMap(sig2 =>
                  reCheck(substCompose(sig2, sig1))
                )
              | NoMatch =>
                switch lhsTy {
                | TyVar(alpha) =>
                  Ok(substCompose(Subst.empty->Map.Int.set(alpha, extendedStructTy), sig1))
                | _ => unify(lhsTy, extendedStructTy)->map(sig2 => substCompose(sig2, sig1))
                }
              }
            }
          }
        }
      | _ => {
          open StructMatching

          // try inferring that this type is a struct
          let a = Context.freshTyVarIndex()
          let partialAttrs = Attributes.make(TyVar(a))->Attributes.insert(attr, tau)
          let partialStruct = substMono(sig1, Types.TyStruct(Types.PartialStruct(partialAttrs)))
          switch findMatchingStruct(partialAttrs) {
          | OneMatch(matchingStruct) =>
            unify(sig1LhsTy, TyStruct(NamedStruct(matchingStruct.name)))->flatMap(sig2 => {
              reCheck(substCompose(sig2, sig1))
            })
          | MultipleMatches(_) =>
            unify(sig1LhsTy, partialStruct)->flatMap(sig2 => {
              reCheck(substCompose(sig2, sig1))
            })
          | NoMatch =>
            Error(`no struct declaration matches type ${Types.showMonoTy(partialStruct)}`)
          }
        }
      }
    })
  }
}

and collectCoreStmtTypeSubsts = (env: Env.t, stmt: CoreStmt.t): result<Subst.t, string> => {
  switch stmt {
  | CoreExprStmt(expr) => collectCoreExprTypeSubsts(env, expr)
  }
}

let inferCoreExprType = expr => {
  let env = Map.String.empty
  collectCoreExprTypeSubsts(env, expr)->Result.map(subst => {
    (substMono(subst, CoreExpr.typeOf(expr)), subst)
  })
}

let renameStructImpl = (structName: string, f: string): string => {
  `${structName}_${f}`
}

let rec registerDecl = (env, decl: CoreDecl.t): result<(Env.t, Subst.t), string> => {
  switch decl {
  | CoreFuncDecl(f, args, body) =>
    let f = f.contents
    collectFuncTypeSubstsWith(env, args->Array.map(fst), body, f.ty, Some(f.newName))->Result.map(((
      sig,
      _fTy,
      _fTyGen,
    )) => {
      (substEnv(sig, env->Env.addMono(f.name, f.ty)), sig)
    })
  | CoreExternFuncDecl({name: f, args, ret}) => {
      let fTy = funTy(args->Array.map(((x, _)) => x.contents.ty), ret)

      unify(f.contents.ty, fTy)->Result.map(sig => {
        (substEnv(sig, env->Env.addMono(f.contents.name, f.contents.ty)), sig)
      })
    }
  | CoreGlobalDecl(x, _, init) =>
    collectCoreExprTypeSubstsWith(env, init, x.contents.ty)->Result.map(sig => {
      (substEnv(sig, env->Env.addMono(x.contents.name, x.contents.ty)), sig)
    })
  | CoreStructDecl(_, _) =>
    // the struct was already declared in Core.fromDecl
    Ok((env, Subst.empty))
  | CoreImplDecl(typeName, funcs) =>
    switch Context.getStruct(typeName) {
    | Some(struct) =>
      funcs->Array.reduce(Ok((env, Subst.empty)), (acc, (f, args, body)) => {
        acc->Result.flatMap(((gamma, sig)) => {
          // rename the function
          f.contents.newName = renameStructImpl(typeName, f.contents.name)

          let (isMethod, isSelfMutable) =
            args
            ->Array.get(0)
            ->Option.mapWithDefault((false, false), ((arg, mut)) =>
              arg.contents.name == "self" ? (true, mut) : (false, false)
            )

          let (gamma, args) = if isMethod {
            // add the method to the struct's signature
            struct->Struct.addImplementation(f, isSelfMutable)

            // remove the first (self) argument
            let remainingArgs = args == [] ? [] : args->Array.sliceToEnd(1)

            let structTy = TyStruct(NamedStruct(typeName))

            // add the first argument to the environment
            let gammaSelf = switch args->Array.get(0) {
            | Some((arg, _)) => {
                arg.contents.ty = structTy
                gamma->Env.addMono(arg.contents.name, structTy)
              }
            | None => gamma
            }

            (gammaSelf, remainingArgs)
          } else {
            // static function
            struct->Struct.addStaticFunc(f)

            (env, args)
          }

          registerDecl(gamma, CoreFuncDecl(f, args, body))->Result.flatMap(((gamma', sig')) => {
            let sig'' = substCompose(sig', sig)

            // substitute the inferred type for f
            Context.substNameRef(sig'', f)

            // f is not visible in the global scope
            let gamma'' = gamma'->Env.remove(f.contents.name)
            Ok((gamma'', sig''))
          })
        })
      })
    | None => Error(`cannot implement for unknown type "${typeName}"`)
    }
  }
}

let infer = (prog: array<CoreDecl.t>): result<(Env.t, Subst.t), string> => {
  funcRetTyStack->MutableStack.clear

  prog->Array.reduce(Ok((Env.empty, Subst.empty)), (acc, decl) => {
    acc->Result.flatMap(((envn, sign)) =>
      registerDecl(envn, decl)->Result.map(((env, sig)) => (env, substCompose(sig, sign)))
    )
  })
}
