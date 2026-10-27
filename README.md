# Atelier meubles — Odoo 18 Community sous Docker

Cet environnement démarre Odoo et PostgreSQL, crée la base `atelier_meubles` et installe les applications **CRM, Ventes, Achats, Inventaire, Fabrication et Maintenance**. Le module `atelier_meubles` ajoute une étude de coût **par meuble demandé**, crée les centres de travail correspondant à vos phases et relie les machines ainsi que les interventions de maintenance à la fabrication.

## Démarrage

Prérequis : Docker Desktop démarré, avec les conteneurs Linux activés.

### Démarrage en un clic

Double-cliquez sur `start-atelier.bat` — **aucune commande à saisir**. Le script :

1. active **WSL** et **VirtualMachinePlatform** s’ils ne le sont pas (redémarrage auto + reprise après connexion si Windows l’exige) ;
2. installe **Docker Desktop** (via `winget`, sinon téléchargement direct), le configure en WSL2 et le démarre ;
3. crée `.env` si besoin, lance la stack, attend le module, ouvre **http://localhost:8069** et exécute le smoke test.

Acceptez une seule fois la demande **UAC** (droits administrateur) si WSL/Docker doivent être installés. Un journal est écrit dans `logs/start-atelier.log` (utile si un autre PC échoue). La fenêtre se ferme toute seule à la fin.

Prérequis machine : Windows 10 2004+ / Windows 11, virtualisation CPU activée dans le BIOS (Intel VT-x / AMD-V), Internet pour le premier téléchargement.

Dans PowerShell, depuis ce dossier :

```powershell
Copy-Item .env.example .env
# Modifiez ODOO_DB_PASSWORD dans .env avant le premier démarrage.
docker compose up --build -d
docker compose ps
```

La première installation peut prendre plusieurs minutes. Suivez-la avec `docker compose logs -f init`. Quand `init` a terminé avec le code 0 et que `odoo` est démarré, ouvrez **http://localhost:8069**. Connexion initiale de cette base de test : `admin` / `admin`. Changez immédiatement ce mot de passe dans les préférences de l'utilisateur administrateur.

Vous pouvez vérifier l'installation du module avec :

```powershell
docker compose exec db psql -U odoo -d atelier_meubles -c "SELECT name, state FROM ir_module_module WHERE name = 'atelier_meubles';"
```

Le résultat attendu est `atelier_meubles | installed`. Si Odoo ne démarre pas, consultez `docker compose logs --tail=100 init odoo db`.

Si `init` échoue avec `password authentication failed for user "odoo"`, le volume PostgreSQL a été créé avec un ancien mot de passe (changer `ODOO_DB_PASSWORD` dans `.env` après le premier démarrage ne le met pas à jour). Remettez l'ancien mot de passe dans `.env`, ou repartez de zéro avec `docker compose down -v` puis `docker compose up --build -d`.

Pour arrêter sans effacer les données : `docker compose down`. Pour redémarrer : `docker compose up -d`. **`docker compose down -v` efface la base et les fichiers Odoo** ; utilisez cette commande uniquement pour repartir de zéro.

Si vous aviez déjà démarré la version précédente du module, conservez vos données et mettez-le à jour :

```powershell
docker compose build init
docker compose stop odoo
docker compose run --rm init odoo -d atelier_meubles -u atelier_meubles --stop-after-init
docker compose up -d odoo
```

## Votre flux dans Odoo

| Votre étape | Dans Odoo |
| --- | --- |
| Demande d'un client | CRM → créer une opportunité pour la demande d'un ou de plusieurs meubles. Saisir les coordonnées et le besoin global. |
| Étude de chaque meuble | Depuis l'opportunité, créer un devis. Ajouter **une ligne par meuble** avec quantité et description. Ouvrir chaque ligne pour saisir le coût des matières, de la main-d'œuvre, les autres coûts et les notes techniques. L'onglet **Étude du meuble** totalise les coûts et la marge estimée de la demande. Joindre les plans au devis. |
| Devis | Ventes → saisir le prix et le délai de chaque meuble ; envoyer le devis complet au client, puis confirmer la commande après accord. |
| Achat des fournitures | **Magasin — Achats** : demander les prix aux fournisseurs, confirmer les commandes et réceptionner les panneaux, quincailleries et matières en Inventaire. |
| Fabrication par article | Pour chaque meuble du devis, définir un produit fabriqué et sa nomenclature. Avec les routes **MTO + Fabriquer**, la confirmation de la commande déclenche les OF des meubles demandés. Le lien commande ↔ OF est visible dans Odoo. Chaque sous-ensemble peut aussi avoir son **propre OF** grâce à une nomenclature à plusieurs niveaux. |
| Kit projet | **Magasin — Préparation du kit projet** : regrouper les composants et les affecter au meuble à fabriquer. Cette phase peut être une opération dans la nomenclature. |
| Passage dans les ateliers | Dans chaque nomenclature, ajouter les **opérations** nécessaires et leurs **centres de travail**. Odoo crée les **ordres de travail (OT)** correspondants dans l'OF. |
| Conditionnement et livraison | **Conditionnement — Emballage** peut être une opération du meuble fini. **Livraison** se valide ensuite dans Inventaire, à partir de la commande client. |

### Ateliers et phases (orthographe corrigée)

| Atelier | Phases |
| --- | --- |
| Magasin | Achat des fournitures ; préparation du kit projet (regroupement des composants à affecter au meuble à fabriquer). |
| Menuiserie | Découpe ; usinage ; assemblage ; finition ; peinture. |
| Tapisserie | Garnissage ; moussage ; coupe du tissu ; couture ; finition. |
| Conditionnement | Emballage ; livraison. |

Le module crée **12 centres de travail** pour les phases de kit projet, menuiserie, tapisserie et emballage. Sur la nomenclature de chaque meuble, utilisez le bouton **Ajouter le parcours complet des ateliers** : il ajoute les 12 opérations dans cet ordre, sans doublons. Ainsi, l'OF créé pour ce meuble produit 12 OT, un par phase. Vous pouvez ensuite adapter la nomenclature si un article suit un parcours plus court. Les achats et la livraison restent des opérations des applications Achats et Inventaire.

### Configuration initiale à faire dans l'interface

1. Dans **Fabrication → Configuration → Paramètres**, activer **Ordres de travail**. Les centres de travail ci-dessous sont créés automatiquement par le module.
2. Dans **Inventaire → Configuration → Paramètres**, activer les **routes / itinéraires multiples** pour afficher les routes sur les fiches produits. Le module active déjà la route **Réapprovisionner sur commande (MTO)** de l'entrepôt par défaut.
3. Créer les produits achetés (panneau, vis, colle, finition), les fournisseurs et leurs prix d'achat. Créer aussi **un produit fabriqué pour chaque type de meuble** à proposer (par exemple bureau, table et canapé) et les sous-ensembles nécessaires. Suivre les stocks des matières et des outils avec des produits distincts. Les outils réutilisables sont gérés en stock, mais ne sont pas consommés dans la nomenclature de chaque meuble.
4. Créer d'abord les nomenclatures des éléments : `Plateau` = panneaux + finition ; `Piètement` = bois + vis. Créer ensuite `Bureau fini` = `Plateau` + `Piètement` + vis. Utiliser **Ajouter le parcours complet des ateliers** sur chaque nomenclature qui doit passer par toutes les phases. Supprimer les opérations non requises sur les éléments dont le parcours est plus court.
5. Pour générer automatiquement un OF depuis chaque meuble de la commande client, sélectionner les routes **MTO + Fabriquer** sur les meubles finis. Pour générer un OF distinct pour chaque sous-ensemble demandé par l'OF principal, choisir également **MTO + Fabriquer** sur chaque sous-ensemble. Sans ces routes, créez les OF manuellement. Pour les matières, vous pouvez commencer par des achats manuels ; les fournisseurs et les routes **MTO + Acheter** permettent ensuite de générer des demandes de prix.

### Test rapide conseillé

Créez un client `Client Démo` et une opportunité demandant **un bureau et une banquette**. Créez un seul devis avec deux lignes, une par meuble. Saisissez les coûts estimés de chacune, puis vérifiez les totaux dans l'onglet **Étude du meuble**. Confirmez le devis, achetez et réceptionnez les matières, puis traitez les OF du bureau et de la banquette ainsi que leurs éventuels sous-ensembles. Suivez les OT de menuiserie pour le bureau, et ceux de menuiserie et de tapisserie pour la banquette. Terminez l'emballage et validez la livraison. Vérifiez le bouton des OF sur la commande client, les achats, les mouvements de stock et les ordres de travail.

Un test automatisé vérifie la partie devis → OF → OT avec deux meubles et annule ensuite sa transaction, sans laisser de données de démonstration :

```powershell
Get-Content scripts/smoke_test.py -Raw | docker compose run -T --rm init odoo shell -d atelier_meubles
```

Résultat attendu : `OK: 2 meubles, coûts, 2 OF, 12 OT/OF, achat, livraison et maintenance`.

### Maintenance des machines

L'application **Maintenance** est installée avec le module. Créez une fiche par machine dans **Maintenance → Équipement**, avec catégorie, numéro de série, date de mise en service, technicien et **Atelier / phase**. Par exemple, affectez la scie à **Menuiserie — Découpe** et la machine à coudre à **Tapisserie — Couture**.

Créez des **demandes de maintenance préventive** (entretien planifié, éventuellement récurrent) et **corrective** (panne), attribuez un responsable et une date, puis suivez leur statut dans Maintenance. Sur la demande, vous pouvez renseigner l'**OF** et l'**OT** concernés. Ces liens servent à la traçabilité ; cette version ne bloque pas automatiquement la planification du centre de travail pendant une intervention.

## Portée

Il s'agit d'un environnement **local de test**. Les coûts d'étude sont des **estimations saisies manuellement**, par unité et dans la devise du devis ; ils ne sont pas remplacés automatiquement par les coûts réels des achats ou des OF. L'étude ne bloque pas automatiquement la confirmation. Les nomenclatures, fournisseurs, coûts et règles d'approvisionnement doivent être adaptés à vos meubles réels. Avant une utilisation en production, définissez les droits d'accès, les sauvegardes, les mots de passe, la messagerie et l'hébergement sécurisé.

Références Odoo : [nomenclatures à plusieurs niveaux](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/manufacturing/advanced_configuration/sub_assemblies.html), [centres de travail](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/manufacturing/advanced_configuration/using_work_centers.html), [réapprovisionnement MTO](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/inventory/warehouses_storage/replenishment/mto.html), [demandes de maintenance](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/maintenance/maintenance_requests.html).
