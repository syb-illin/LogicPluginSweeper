<p align="center">
  <img src="Assets/LogicPluginSweeper-logo.jpeg" alt="LogicPluginSweeper" width="900">
</p>

<p align="center">
  <strong>Nettoyez vos plugins audio macOS en toute sécurité.</strong><br>
  Inventoriez, analysez et récupérez de l’espace sans supprimer vos plugins par erreur.
</p>

<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-26%2B%20%7C%20ARM64-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 26 or later ARM64"></a>
  <a href="https://github.com/syb-illin/LogicPluginSweeper/releases"><img src="https://img.shields.io/github/v/release/syb-illin/LogicPluginSweeper?display_name=tag&sort=semver&label=release&style=flat-square" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/syb-illin/LogicPluginSweeper?color=22c55e&style=flat-square" alt="MIT License"></a>
</p>

## Fonctionnalités

- Inventaire des plugins **AU, VST, VST3, AAX et CLAP**.
- Mesure de l’espace disque occupé et de l’espace récupérable.
- Analyse des projets Logic Pro `.logicx` et statistiques d’utilisation des plugins.
- Cache local persistant des projets, conservé après fermeture de l’app et supprimable dans les réglages ; les projets modifiés sont réanalysés.
- Fiche plugin avec réputation sourcée quand une donnée vérifiée est disponible, et recherche web manuelle sinon.
- Recherche globale et tri par nom, taille ou fréquence d’utilisation.
- Suggestions de nettoyage avec sélection groupée et avertissements de sécurité.
- Suppression réversible avec restauration depuis l’application.
- Suppression protégée : choix d’un dossier, ZIP complet et manifeste TXT de restauration avant toute modification.
- Autorisation administrateur demandée uniquement lorsque macOS protège le dossier du plugin.
- Empreinte élargie depuis le contenu du bundle : plugin, presets, préférences, Application Support et caches détectables.
- Historique des actions et rapports exportables en CSV, JSON et PDF.
- Détection des crash logs macOS associés aux plugins.
- Vérification manuelle des Audio Units depuis leur fiche, avec résultat de validation enregistré.
- Notifications macOS à la fin des analyses et des opérations importantes.
- Interface native, mode clair, mode sombre et thèmes personnalisables.
- Mise à jour depuis GitHub Releases avec canaux Stable et Nightly.
- Interface disponible en français et en anglais.

## Télécharger

Les versions publiées sont disponibles dans la section [Releases](https://github.com/syb-illin/LogicPluginSweeper/releases).

La version publiée est définie une seule fois dans `VERSION`. Le workflow refuse automatiquement un tag qui ne correspond pas à ce fichier ; le badge de release, le nom des archives et la version affichée dans l’application restent ainsi alignés.

Téléchargez l’archive `.zip` ou le `.dmg` correspondant à votre Mac, ouvrez l’application, puis suivez les instructions de macOS si une confirmation de sécurité est demandée.

Le DMG contient aussi **LogicPluginSweeper Uninstaller.app**, un désinstalleur autonome utilisable même si l’application principale ne démarre plus.

> Les versions actuellement distribuées ne sont pas encore signées ni notarisées avec un certificat Developer ID. La signature et la notarisation seront ajoutées lorsque les identifiants Apple de distribution seront configurés.

## Compatibilité

- macOS 26 Tahoe ou macOS 27 Golden Gate, et versions ultérieures.
- Mac Apple Silicon ARM64.
- Projets Logic Pro `.logicx` accessibles par l’utilisateur.

L’analyse inspecte aussi les chaînes lisibles du `ProjectData` binaire de Logic. Elle relie les plugins aux projets et expose une piste uniquement lorsqu’un libellé voisin est suffisamment identifiable ; sinon la relation reste explicitement au niveau projet. Un projet illisible ou sans référence exploitable n’est jamais interprété comme une preuve qu’un plugin est inutilisé.

## Utilisation

1. Lancez LogicPluginSweeper.
2. Choisissez une analyse des plugins ou déposez un projet `.logicx` dans la fenêtre.
3. Consultez l’inventaire, l’espace occupé et les recommandations.
4. Vérifiez les dépendances Logic Pro avant toute action.
5. Supprimez les éléments sélectionnés avec ou sans sauvegarde externe, ou restaurez-les depuis l’historique.

## Désinstallation

Ouvrez **LogicPluginSweeper Uninstaller.app** depuis le DMG, quittez LogicPluginSweeper, puis sélectionnez l’application installée si elle n’est pas détectée dans `/Applications`. Le désinstalleur déplace l’application vers la corbeille et supprime par défaut uniquement le cache recréable des projets. Il affiche le nombre de fichiers du cache, sa taille, sa dernière modification et son emplacement.

L’historique et les plugins conservés pour restauration restent en place par défaut. Vous pouvez exporter une copie du dossier de données et des préférences avant de choisir explicitement leur suppression définitive. Cet export conserve les noms et l’arborescence des fichiers ; pour restaurer les plugins depuis l’application après réinstallation, remettez le dossier `LogicPluginSweeper` exporté dans `~/Library/Application Support/`. Les plugins audio toujours installés ne sont jamais supprimés par le désinstalleur. Si macOS refuse la mise à la corbeille de l’application, aucune donnée locale n’est effacée.

Depuis un projet analysé, sélectionnez un morceau pour voir ses plugins. Depuis un plugin, ouvrez sa fiche pour voir les projets qui le référencent, sa taille, son format, son état, son emplacement et les liens officiels disponibles. Les mesures CPU/mémoire ne sont pas affichées tant qu’un profilage dédié et fiable n’a pas été exécuté.

## Confidentialité

La télémétrie d’usage est activée par défaut afin d’améliorer l’application. Elle peut être désactivée dans les réglages. Les données collectées sont limitées aux événements d’utilisation agrégés et n’incluent pas les chemins locaux, les noms de projets Logic ou les noms de fichiers personnels.

## Licence

LogicPluginSweeper est distribué sous licence [MIT](LICENSE).

## Liens

- [Téléchargements](https://github.com/syb-illin/LogicPluginSweeper/releases)
- [Signaler un problème](https://github.com/syb-illin/LogicPluginSweeper/issues)
- [Proposer une amélioration](https://github.com/syb-illin/LogicPluginSweeper/issues/new)
