# Glasgow Proof Labels — Plan Exhaustif

Chaque contrainte émise par Glasgow dans le fichier `.pbp` doit avoir un label unique.
En VeriPB, deux pas de preuve distincts ne peuvent pas partager le même label.

Conventions de nommage :
- `<p>` = nom du sommet pattern (e.g. `v3`)
- `<t>` = nom du sommet cible (e.g. `u7`)
- `<q>` = nom du voisin pattern
- `<var>` = nom de variable `p_t` (concaténation produite par Glasgow, e.g. `v3_u7`)
- `<g>` = indice du graphe supplémentaire (entier)
- `<line>` = numéro de ligne proof = `_imp->proof_line + 1` au moment de l'émission (garantit l'unicité pour les pas non paramétrés)

---

## 1. Contraintes OPB (fichier `.opb`, permanentes)

Ces contraintes sont dans le modèle, pas dans le fichier proof. Elles ont toutes un label
et sont référencées par leur label dans les expressions pol/ia/rup.

| Label | Format | Représente | Fonction (proof.cc) | Statut |
|---|---|---|---|---|
| `@al1<p>` | `@al1v3` | Au moins un : Σ x[p,t] ≥ 1, p doit être assigné | `create_cp_variable` L109 | ✅ OK |
| `@am1<p>` | `@am1v3` | Au plus un : Σ −x[p,t] ≥ −1, p assigné à un seul | `create_cp_variable` L119 | ✅ OK |
| `@inj<t>` | `@injt5` | Injectivité : Σ −x[p,t] ≥ −1, au plus un pattern map sur t | `create_injectivity_constraints` L135 | ✅ OK |
| `@g0adj<p>_<t>_<q>` | `@g0adjv3_u7_v2` | Adjacence g=0 : si p→t alors q→N(t) (obligation de voisinage) | `create_adjacency_constraint` L166 | ✅ OK |
| `@forb<var>` | `@forbv3_u7` | Affectation interdite pré-calculée : ¬x[p,t] | `create_forbidden_assignment_constraint` L153 | ✅ OK |
| `@noedge<p>_<q>` | `@noedgev1_v4` | Non-arête entre p et q (encodage clique) | `create_non_edge_constraint` L832 | ✅ OK |

---

## 2. Élimination par degrés (`incompatible_by_degrees`)

Structure pour la paire (p,t), premier appel (guard `!eliminations.contains`), puis appels suivants
pour g supplémentaires (sans guard, sans label sur l'ia) :

```
pol  @g0adj_p_t_n1 @inj_r1 + ... s ;    ← K+1 : dérive 1 ~x[p,t] ≥ 1 via combinaison
@elimdeg<var> ia 1 ~x[p,t] ≥ 1 : K+1 ; ← K+2 : réaffirme sous label (premier appel seulement)
del id K+1 ;                             ← marque K+1 pour suppression (VeriPB)
```

`eliminations[(p,t)] = K+2`. Référencé par `incompatible_by_nds`.

**Correction :** ajouter un label sur K+1 (pol), garder le label sur K+2 (ia), garder `del id K+1`
inchangé (TrimAnalyser ignore `del id` — aucun impact sur le cône).

Structure cible :
```
@elimdegpol<var> pol @g0adj_p_t_n1 @inj_r1 + ... s ;  ← K+1 : NOUVEAU label
@elimdeg<var> ia 1 ~x[p,t] ≥ 1 : K+1 ;               ← K+2 : label existant, inchangé
del id K+1 ;                                            ← inchangé
```

Pour les appels suivants (même paire, g différent, sans guard) : les pas pol et ia ne reçoivent
pas de label — le trimmer déterminera s'ils sont dans le cône.

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@elimdegpol<var>` | `@elimdegpolv3_u7` | pol K+1 : dérive ¬x[p,t] par combinaison d'adjacences et d'injectivité | ⚠️ NOUVEAU |
| `@elimdeg<var>` | `@elimdegv3_u7` | ia K+2 : réaffirme ¬x[p,t] sous forme ia, antécédent = K+1 | ✅ déjà présent, conserver |

---

## 3. Élimination par NDS (`incompatible_by_nds`)

NDS = "Neighbourhood Degree Sequence". Jamais déclenché dans nos runs actuels.

### 3a. Prérequis NDS (`need_elimination`)

```
setlvl 0 ;
@elimnds<var> rup 1 ~x[n,u] ≥ 1 ;   ← rup niveau 0 : élimine (n,u) via propagation
setlvl <active> ;
```

`eliminations[(n,u)] = ligne de ce rup`. Référencé explicitement dans le pol NDS.

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@elimnds<var>` | `@elimndsv2_u4` | rup : (n,u) doit être éliminé avant NDS, vérifié par UP | ✅ OK (déjà sur le bon pas) |

### 3b. Pol et ia NDS (`incompatible_by_nds`)

```
pol @g0adj_... @inj_... + <eliminations[n,u]> + ... s ;  ← pol NDS : combine adjacences + éliminations
<label?> ia 1 ~x[p,t] ≥ 1 : <pol_line> ;                 ← ia NDS : réaffirme sous forme ia
del id <pol_line> ;
```

**Correction :** labeliser les deux pas. Le pol reçoit `@elimndspol<var>`. L'ia reçoit
`@elimndsconc<var>` (et non `@elimnds<var>` qui est réservé au rup de `need_elimination` — garder
les deux espaces de noms distincts pour éviter tout conflit).

Structure cible :
```
@elimndspol<var> pol ... s ;              ← NOUVEAU label
@elimndsconc<var> ia 1 ~x[p,t] ≥ 1 : <pol_line> ;  ← NOUVEAU label (remplace guard conditionnel)
del id <pol_line> ;                       ← inchangé
```

Note : le code actuel applique conditionnellement `@elimnds<var>` sur l'ia uniquement si
`!eliminations.contains(p,t)`. Après correction : appliquer `@elimndsconc<var>` toujours
(le guard peut rester pour éviter les doublons si la paire est déjà éliminée, mais le label
change de préfixe).

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@elimndspol<var>` | `@elimndspolv3_u7` | pol : p→t impossible par NDS, combine adjacences + prérequis éliminés | ⚠️ NOUVEAU |
| `@elimndsconc<var>` | `@elimndsconcv3_u7` | ia : réaffirme ¬x[p,t] sous forme ia après pol NDS | ⚠️ NOUVEAU (remplace `@elimnds<var>` conditionnel sur l'ia) |

---

## 4. Élimination par boucles (`incompatible_by_loops`)

```
@loop<var> rup 1 ~x[p,t] ≥ 1 ;  ← rup : p a une boucle, t n'en a pas, donc p→t impossible
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@loop<var>` | `@loopv3_u7` | rup : p→t impossible, p a une auto-boucle absente chez t | ✅ OK |

---

## 5. Graphes supplémentaires — `create_exact_path_graphs`

Calcule l'adjacence dans G^(g×2) via des chemins de longueur 2 dans G.
Tous les pas intermédiaires sont à `level 1` (wiped logiquement, mais pas par TrimAnalyser).
Le seul pas permanent est le `@gNadj ia` final à `level 0`.

Structure par appel pour le triplet (g, p, q, t) — si non caché :

```
setlvl 1 ;
@pathg<g>_<p>_<t>_<q>_s1   pol  <g0adj...> + <g0adj...> + ... s ;
@pathg<g>_<p>_<t>_<q>_ia1  ia   1 ~x[p,t] Σ x[q,u] ≥ 1 : <line> ;
@pathg<g>_<p>_<t>_<q>_s2   pol  <line> @inj<t> + s ;
@pathg<g>_<p>_<t>_<q>_ia2  ia   1 ~x[p,t] Σ x[q,u∉{t}] ≥ 1 : <line> ;

# Pour chaque u ∈ two_away_from_t à exclure :
@pathg<g>_<p>_<t>_<q>_eu<u>s   pol  <g0adj...> + @am1<b> + @inj<z> + ... s ;
@pathg<g>_<p>_<t>_<q>_eu<u>ia  ia   1 ~x[p,t] 1 ~x[q,u] ≥ 1 : <line> ;

# Si plusieurs exclusions :
@pathg<g>_<p>_<t>_<q>_sfin     pol  <ia2_line> <eu1ia_line> + ... s ;

setlvl 0 ;
@g<g>adj<p>_<t>_<q>  ia  1 ~x[p,t] Σ x[q,v] ≥ 1 : <line> ;
wiplvl 1 ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@pathg<g>_<p>_<t>_<q>_s1` | `@pathg2_v3_u7_v2_s1` | pol : combine les g0adj des intermédiaires entre p et q via t | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_ia1` | `@pathg2_v3_u7_v2_ia1` | ia : si p→t alors q→N_2(t) (2-chemins depuis t) | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_s2` | `@pathg2_v3_u7_v2_s2` | pol : exclut t lui-même via injectivité | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_ia2` | `@pathg2_v3_u7_v2_ia2` | ia : restriction après exclusion de t | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_eu<u>s` | `@pathg2_v3_u7_v2_euu5s` | pol : prouve ¬x[p,t] ∨ ¬x[q,u] pour u insuffisamment connecté | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_eu<u>ia` | `@pathg2_v3_u7_v2_euu5ia` | ia : contrainte paire (p→t) ∧ (q→u) impossible | ⚠️ NOUVEAU |
| `@pathg<g>_<p>_<t>_<q>_sfin` | `@pathg2_v3_u7_v2_sfin` | pol : combine toutes les exclusions en une seule contrainte | ⚠️ NOUVEAU |
| `@g<g>adj<p>_<t>_<q>` | `@g2adjv3_u7_v2` | ia niveau 0 : adjacence dans G^(g×2), contrainte permanente | ✅ OK |

Note : si un appel est servi depuis `cached_proof_lines`, aucun nouveau pas n'est émis.
Le label `@g<g>adj<p>_<t>_<q>` est alors copié du cache — pas de doublon.

---

## 6. Graphes supplémentaires — `hack_in_shape_graph`

```
@g<g>adj<p>_<t>_<q>  a  1 ~x[p,t] Σ x[q,u] ≥ 1 ;
```

Pas de type `a` (axiome) : assertion directe, sans dérivation. Permanent, niveau 0.

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@g<g>adj<p>_<t>_<q>` | `@g2adjv3_u7_v2` | a : adjacence dans le shape graph g, assertée directement | ✅ OK |

---

## 7. Graphes supplémentaires — `create_distance3_graphs_but_actually_distance_1`

Cas G^3 où la distance réelle est 1 (réutilise `@g0adj`).

```
@g<g>adj<p>_<t>_<q>  ia  1 ~x[p,t] Σ x[q,u] ≥ 1 : @g0adj<p>_<t>_<q> ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@g<g>adj<p>_<t>_<q>` | `@g3adjv3_u7_v2` | ia : adjacence G^3 par dist-1, dérive directement depuis g0adj | ✅ OK |

---

## 8. Graphes supplémentaires — `create_distance3_graphs_but_actually_distance_2`

Cas G^3 où la distance réelle est 2. Pas intermédiaires à `level 1`.

```
setlvl 1 ;
@d2g<g>_<p>_<q>_<t>_s1  pol  @g0adj<p>_<pathv>_<t> @g0adj<pathv>_<q>_<u> + ... ;
@d2g<g>_<p>_<q>_<t>_ia1 ia   1 ~x[p,t] Σ x[q,u∈N_2(t)] ≥ 1 : <line> ;
setlvl 0 ;
@g<g>adj<p>_<t>_<q>  ia  1 ~x[p,t] Σ x[q,u∈N_3(t)] ≥ 1 : <line> ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@d2g<g>_<p>_<q>_<t>_s1` | `@d2g3_v3_v2_u7_s1` | pol : compose deux g0adj pour obtenir la voisinage à dist-2 | ⚠️ NOUVEAU |
| `@d2g<g>_<p>_<q>_<t>_ia1` | `@d2g3_v3_v2_u7_ia1` | ia niveau 1 : si p→t alors q→N_2(t) | ⚠️ NOUVEAU |
| `@g<g>adj<p>_<t>_<q>` | `@g3adjv3_u7_v2` | ia niveau 0 : adjacence G^3 dist-2, permanente | ✅ OK |

---

## 9. Graphes supplémentaires — `create_distance3_graphs`

Cas G^3 via chemin de longueur 2 avec un vertex intermédiaire. Deux pol intermédiaires.

```
setlvl 1 ;
@d3g<g>_<p>_<q>_<t>_s1  pol  @g0adj<p>_<b1>_<t> @g0adj<b1>_<b2>_<u> + ... ;
@d3g<g>_<p>_<q>_<t>_ia1 ia   1 ~x[p,t] Σ x[b2,u∈N_2(t)] ≥ 1 : <line> ;
@d3g<g>_<p>_<q>_<t>_s2  pol  <ia1_line> @g0adj<b2>_<q>_<u> s + ... ;
setlvl 0 ;
@g<g>adj<p>_<t>_<q>  ia  1 ~x[p,t] Σ x[q,u∈N_3(t)] ≥ 1 : <line> ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@d3g<g>_<p>_<q>_<t>_s1` | `@d3g3_v3_v2_u7_s1` | pol : premier saut du chemin dist-3 | ⚠️ NOUVEAU |
| `@d3g<g>_<p>_<q>_<t>_ia1` | `@d3g3_v3_v2_u7_ia1` | ia niveau 1 : si p→t alors b2→N_2(t) | ⚠️ NOUVEAU |
| `@d3g<g>_<p>_<q>_<t>_s2` | `@d3g3_v3_v2_u7_s2` | pol : deuxième saut, obtient q→N_3(t) | ⚠️ NOUVEAU |
| `@g<g>adj<p>_<t>_<q>` | `@g3adjv3_u7_v2` | ia niveau 0 : adjacence G^3 via chemin longueur 2, permanente | ✅ OK |

---

## 10. Hall sets et violateurs de Hall (`emit_hall_set_or_violator`)

```
@hall<line>  pol  @al1<l1> @al1<l2> + @inj<r1> + @inj<r2> + ... ;
```

Le label utilise le numéro de ligne (`_imp->proof_line + 1`) car le même ensemble de sommets
peut théoriquement réapparaître à des nœuds de recherche différents.

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@hall<line>` | `@hall1847` | pol : l'ensemble lhs n'a pas assez de valeurs disponibles (violateur de Hall) | ⚠️ NOUVEAU |

---

## 11. Cas pattern > target (`failure_due_to_pattern_bigger_than_target`)

Émis au plus une fois. Le violateur de Hall global (somme de tous les @al1 + @inj).

```
@ptbig  pol  @al1<p1> @al1<p2> + ... @inj<t1> + @inj<t2> + ... ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@ptbig` | `@ptbig` | pol : |pattern| > |target|, contradiction directe par Hall | ⚠️ NOUVEAU |

---

## 12. Recherche — nogoods de propagation (`propagation_failure`)

Un pas par nœud de recherche où la propagation échoue.

```
@prop<line>  rup  1 ~x[d1] 1 ~x[d2] ... ≥ 1 ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@prop<line>` | `@prop2341` | rup : les décisions d1…dk mènent à contradiction par propagation | ⚠️ NOUVEAU |

---

## 13. Recherche — backtracking (`incorrect_guess`)

Un pas par backtrack (failure ou simple backtrack).

```
@guess<line>  rup  1 ~x[d1] 1 ~x[d2] ... ≥ 1 ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@guess<line>` | `@guess2347` | rup : nogood accumulé des mauvaises décisions d1…dk−1 | ⚠️ NOUVEAU |

---

## 14. Recherche — redémarrage (`post_restart_nogood`)

```
@nogood<line>  rup  1 ~x[d1] 1 ~x[d2] ... ≥ 1 ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@nogood<line>` | `@nogood4021` | rup : nogood sauvegardé avant restart | ⚠️ NOUVEAU |

---

## 15. Preuve de clique homomorphe (`start_hom_clique_proof`, `finish_hom_clique_proof`, `add_hom_clique_non_edge`)

Utilisé pour le bound couleur dans les variantes MCS/Hom.

```
@hombd<q>_<t>_<line>    rup  1 ~x[p,t] Σ x[q,u] ≥ 1 ;   # un par q dans p_clique
@hompol<line>           pol  <rup1> <rup2> + ... ;
@hominj<p>_<q>_<t>_<line>  rup  1 ~x[p,t] 1 ~x[q,t] ≥ 1 ;   # non-arête par injectivité
@homdom<p>_<t>_<u>_<line>  rup  1 ~x[p,t] 1 ~x[p,u] ≥ 1 ;   # non-arête par domaine
@homfin<p>_<t>          rup  1 ~x[p,t] ≥ 1 ;               # conclusion finale
@homcross<p>_<t>_<q>_<u>_<line>  rup  1 ~x[pp,tt] 1 ~x[p,t] 1 ~x[q,u] ≥ 1 ;   # add_hom_clique_non_edge
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@hombd<q>_<t>_<line>` | `@hombdv2_u5_1234` | rup : borne de clique pour q dans le voisinage de p\t | ⚠️ NOUVEAU |
| `@hompol<line>` | `@hompol1240` | pol : combine les bornes de clique en objectif | ⚠️ NOUVEAU |
| `@hominj<p>_<q>_<t>_<line>` | `@hominjv1_v3_u5_1250` | rup : non-arête clique (injectivité) | ⚠️ NOUVEAU |
| `@homdom<p>_<t>_<u>_<line>` | `@homdomv1_u5_u6_1255` | rup : non-arête clique (domaine) | ⚠️ NOUVEAU |
| `@homfin<p>_<t>` | `@homfinv3_u7` | rup : conclusion finale du block clique, ¬x[p,t] | ⚠️ NOUVEAU |
| `@homcross<line>` | `@homcross1280` | rup : non-arête clique croisée entre deux paires | ⚠️ NOUVEAU |

---

## 16. Borne couleur MCS (`colour_bound`)

```
@colcc<line>  pol  @noedge<a>_<b> ... <N> * + <N+1> d ... ;   # un par composante connexe
@colfin<line> pol  @colcc1 @colcc2 + ... <obj_line> + ;        # total
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@colcc<line>` | `@colcc3001` | pol : borne couleur pour une composante connexe | ⚠️ NOUVEAU |
| `@colfin<line>` | `@colfin3010` | pol : borne couleur totale combinée | ⚠️ NOUVEAU |

---

## 17. Borne MCS par partition (`mcs_bound`)

```
@mcspart<line>  pol  @al1<v> @al1<v> + @inj<r> + ... ;   # un par partition r.size < l.size
@mcsfin<line>   pol  <obj_line> @mcspart1 + @mcspart2 + ... ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@mcspart<line>` | `@mcspart4001` | pol : une partition viole le critère MCS (|rhs| < |lhs|) | ⚠️ NOUVEAU |
| `@mcsfin<line>` | `@mcsfin4010` | pol : borne MCS totale combinée avec objectif | ⚠️ NOUVEAU |

---

## 18. Retour arrière sur variables binaires (`backtrack_from_binary_variables`)

Deux modes : simple (un rup) ou hom-colour (plusieurs rup imbriqués).

```
@binback<line>  rup  1 ~x<b1> 1 ~x<b2> ... ≥ 1 ;   # mode simple
@binback<line>  rup  1 ~x[p,t] 1 ~x<b1> ... ≥ 1 ;  # mode hom (plusieurs)
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@binback<line>` | `@binback5001` | rup : backtrack depuis les variables binaires MCS | ⚠️ NOUVEAU |

---

## 19. Connectivité — graphe sous-jacent (`not_connected_in_underlying_graph`)

```
@notconn<y>_<line>  rup  1 ~x<y> Σ 1 ~x<v> ≥ 1 ;
```

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@notconn<y>_<line>` | `@notconn7_5001` | rup : sommet y non connecté au reste des sommets sélectionnés | ⚠️ NOUVEAU |

---

## 20. Non-arêtes de clique (`create_clique_nonedge`)

```
@cliqedge<v>_<w>  rup  1 ~x<v> 1 ~x<w> ≥ 1 ;
```

Le label utilise les indices v et w (toujours v < w dans le code).

| Label | Format | Représente | Statut |
|---|---|---|---|
| `@cliqedge<v>_<w>` | `@cliqedge3_7` | rup : non-arête entre les sommets v et w dans l'encodage clique | ⚠️ NOUVEAU |

---

## Récapitulatif

| Catégorie | Nombre de types | Déjà OK | À ajouter | À créer |
|---|---|---|---|---|
| OPB model | 6 | 6 | 0 | 0 |
| Élimination degrés pol | 1 | 0 | 1 | 0 |
| Élimination degrés ia | 1 | 1 | 0 | 0 |
| Élimination NDS prérequis rup | 1 | 1 | 0 | 0 |
| Élimination NDS pol | 1 | 0 | 0 | 1 |
| Élimination NDS ia | 1 | 0 | 0 | 1 |
| Élimination boucles | 1 | 1 | 0 | 0 |
| Graphes supp. — exact path | 8 | 1 | 0 | 7 |
| Graphes supp. — shape | 1 | 1 | 0 | 0 |
| Graphes supp. — dist3 dist1 | 1 | 1 | 0 | 0 |
| Graphes supp. — dist3 dist2 | 3 | 1 | 0 | 2 |
| Graphes supp. — dist3 | 4 | 1 | 0 | 3 |
| Hall sets | 1 | 0 | 0 | 1 |
| Pattern > target | 1 | 0 | 0 | 1 |
| Recherche — propagation | 1 | 0 | 0 | 1 |
| Recherche — backtrack | 1 | 0 | 0 | 1 |
| Recherche — restart | 1 | 0 | 0 | 1 |
| Clique hom | 6 | 0 | 0 | 6 |
| Borne couleur | 2 | 0 | 0 | 2 |
| Borne MCS | 2 | 0 | 0 | 2 |
| Backtrack binaire | 1 | 0 | 0 | 1 |
| Connectivité | 1 | 0 | 0 | 1 |
| Non-arêtes clique | 1 | 0 | 0 | 1 |
| **Total** | **46** | **14** | **1** | **31** |

---

## Notes d'implémentation

### Correction `@elimdegpol` (priorité haute — impact mesh 99.7%)

Dans `incompatible_by_degrees` (proof.cc L269-313) :
1. Calculer `bool first_time = !_imp->eliminations.contains(pair{p.first, t.first})` avant d'émettre le pol
2. Si `first_time` : émettre `@elimdegpol<var>` devant le `pol`
3. Garder l'ia avec son label `@elimdeg<var>` (guard existant inchangé)
4. Garder `del id K+1` inchangé (TrimAnalyser ignore `del id`)

### Labels dynamiques avec numéro de ligne

Pour tous les labels `<line>` : utiliser `_imp->proof_line + 1` au moment de l'émission.
```cpp
auto step_line = _imp->proof_line + 1;
*_imp->proof_stream << "@prop" << step_line << " rup ...;\n";
++_imp->proof_line;
```

### Unicité des labels intermédiaires `create_exact_path_graphs`

Les labels `@pathg<g>_<p>_<t>_<q>_*` sont uniques par appel car :
- Chaque triplet (g, p, q, t) est traité au plus une fois (cache `cached_proof_lines`)
- Les suffixes `_s1`, `_ia1`, etc. distinguent les pas au sein du même appel
- Le vertex `<u>` dans `_eu<u>*` est le nom du sommet cible à exclure

### TrimAnalyser — métriques à ajouter

- `grim_cone_elimdegpol` : pol K+1 d'élimination par degrés (principal signal mesh)
- `grim_cone_elimdeg` : ia K+2 (existant, inchangé)
- `grim_cone_elimndspol` : pol NDS
- `grim_cone_elimndsconc` : ia NDS conclusion
- `grim_cone_hall` : Hall sets pol
- `grim_cone_prop`, `grim_cone_guess`, `grim_cone_nogood` : recherche
- Métriques intermédiaires `@pathg*` : à décider selon utilité pour classify_supplementals

### Impact sur les runs cluster

Les instances mesh verront `grim_cone_elimdeg > 0` après correction.
Les instances non-mesh avec graphes supplémentaires verront les métriques `@pathg*` > 0.
Les instances avec recherche verront `grim_cone_prop`, `grim_cone_guess` > 0.
