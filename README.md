# Portainer Workspace

## A qui s'adresse cette solution ?

Elle s'adresse principalement aux **développeurs sur des postes Windows
d'entreprise** ou WSL 2 est autorisé. Elle est surtout utile aux équipes qui
ont besoin de Docker et de Compose lorsque Docker Desktop n'est pas une option
ou que le proxy du VPN complique l'utilisation des alternatives.

## I. La problématique

Portainer Workspace configure un poste Docker sous Windows, avec une interface
graphique et sans Docker Desktop ni Rancher Desktop.

Ce projet est né d'un besoin d’équipe : disposer de Docker et d'une interface
de gestion sous Windows sans licence Docker Desktop, alors que l'alternative
testée fonctionnait mal avec le proxy de notre VPN. L'objectif est de rendre
l'installation reproductible et de vérifier dès le départ que Docker peut
télécharger des images sur le réseau de l'entreprise.

Le proxy, l'inspection TLS et le DNS d'entreprise peuvent compliquer
l’accès aux dépôts et aux images Docker. Ce projet utilise WSL 2 et Ubuntu 24.04
pour exécuter Docker CE et Portainer CE, tout en conservant les configurations
réseau et de sécurité de l'entreprise.

```text
Windows -> WSL Ubuntu 24.04 -> systemd -> Docker CE -> Portainer CE -> Chrome
```

Portainer est accessible localement sur **http://127.0.0.1:9002**.

## II. La solution manuelle

Voici les grandes étapes si l'on souhaite configurer le poste sans l'installateur.
Elles supposent que WSL et le proxy de l'entreprise sont déjà disponibles.

1. Dans `%USERPROFILE%\.wslconfig`, ajouter ou modifier les valeurs suivantes
sans effacer les autres paramètres :

```ini
[wsl2]
networkingMode=mirrored
autoProxy=true
dnsTunneling=true

[experimental]
hostAddressLoopback=true
```

Ce fichier configure globalement les distributions **WSL 2** de l'utilisateur.
Les sections `[wsl2]` et `[experimental]` regroupent respectivement les
paramètres principaux et les fonctionnalités expérimentales :

| Paramètre | Rôle |
| --- | --- |
| `networkingMode=mirrored` | Utilise le mode réseau miroir : WSL reprend les interfaces réseau Windows et facilite notamment les échanges entre Windows et Linux. |
| `autoProxy=true` | Demande a WSL de reprendre les informations de proxy HTTP de Windows. Cela ne garantit pas que toutes les variables proxy nécessaires aux applications Linux, notamment HTTPS, soient définies. |
| `dnsTunneling=true` | Fait passer les requêtes DNS de WSL par Windows, pour utiliser sa résolution de noms, y compris selon la configuration de l'entreprise. |
| `hostAddressLoopback=true` | En mode miroir, permet aussi les connexions entre Windows et WSL via les adresses IPv4 attribuées a Windows. Ce paramètre ne sert pas a activer `127.0.0.1`, déjà pris en charge en mode miroir. |

Appliquer avec `wsl --shutdown`, puis installer Ubuntu 24.04 avec
`wsl --install --distribution Ubuntu-24.04 --no-launch`. **⚠️L’arrêt de WSL
interrompt toutes les distributions en cours.**

2. Dans Ubuntu, ajouter ou modifier les lignes suivantes dans `/etc/wsl.conf`,
sans effacer les autres paramètres :

```ini
[boot]
systemd=true
```

Contrairement a `.wslconfig`, ce fichier ne concerne que cette distribution :
`systemd=true` active systemd comme gestionnaire de services, notamment pour
démarrer Docker. Depuis PowerShell, redémarrer la distribution :

```powershell
wsl --terminate Ubuntu-24.04
```

Dans Ubuntu, créer ou modifier `/etc/profile.d/proxy.sh` avec l'adresse du
proxy de votre environnement :

```bash
# Avec un proxy local qui écoute par défaut sur le port 9000,
# ces valeurs conviennent généralement telles quelles. L'adresse du proxy
# et les exceptions NO_PROXY peuvent varier selon la configuration du PC.
export HTTP_PROXY=http://127.0.0.1:9000
export HTTPS_PROXY=http://127.0.0.1:9000
export http_proxy=$HTTP_PROXY
export https_proxy=$HTTPS_PROXY
export NO_PROXY=localhost,127.0.0.1
export no_proxy=$NO_PROXY
```

Pour conserver ces variables avec sudo, exécuter
`sudo visudo -f /etc/sudoers.d/portainer-workspace-proxy` et ajouter :

```text
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy"
```

Si nécessaire, ajouter au magasin de certificats Ubuntu le certificat CA
approuvé par votre équipe informatique. Le fichier doit contenir un seul
certificat au format PEM. Dans Ubuntu, adapter le chemin source (ici,
`C:\Certificates\corporate-root.crt` est accessible sous `/mnt/c`) :

```bash
sudo install -m 0644 /mnt/c/Certificates/corporate-root.crt \
/usr/local/share/ca-certificates/portainer-workspace-corporate.crt
sudo update-ca-certificates
```

Puis recharger le profil et vérifier l’accès aux dépôts :

```bash
source /etc/profile.d/proxy.sh
sudo apt update
```

Voir la [documentation Microsoft sur les fichiers de configuration WSL](https://learn.microsoft.com/fr-fr/windows/wsl/wsl-config)
pour les conditions de disponibilité et les autres options.

3. Installer Docker CE, CLI, containerd, Buildx et Compose depuis le
[depot officiel Docker](https://docs.docker.com/engine/install/ubuntu/).
Configurer le proxy du service Docker, activer et redémarrer ce service avec
systemd, puis vérifier `sudo docker pull hello-world`.

4. Créer le volume et le conteneur Portainer :

```bash
sudo docker volume create portainer_data
sudo docker run -d --name portainer --restart unless-stopped \
-p 127.0.0.1:9002:9000 \
-v /var/run/docker.sock:/var/run/docker.sock \
-v portainer_data:/data portainer/portainer-ce:lts
```

Ouvrir **http://127.0.0.1:9002** et créer rapidement le compte administrateur.
Le socket Docker donne a Portainer un contrôle étendu sur Docker : il est important de protéger
l’accès a son interface.

## III. La solution automatisée

Les scripts a conserver ensemble dans le dossier du projet sont :

| Fichier | Rôle |
| --- | --- |
| [Install-PortainerWorkspace.ps1](./Install-PortainerWorkspace.ps1) | Point d’entrée : configure WSL, installe Ubuntu si nécessaire, orchestre les étapes et crée le lanceur. |
| [bootstrap.sh](./bootstrap.sh) | Configure systemd et le proxy dans Ubuntu, installe Docker CE et deploie Portainer. |
| `Start-DockerUI.ps1` | Génère par l'installateur : démarre WSL, la maintient active avec `sleep infinity`, attend Portainer puis ouvre Chrome en mode application. |

L'installateur transmet le bootstrap local a WSL par l’entrée standard et
l’exécute par phases, notamment pour permettre le redémarrage d'Ubuntu après
l'activation de systemd. Il exécute les validations `apt-get update` et
`docker pull hello-world`. Il configure Docker et Portainer pour redémarrer
quand la distribution démarre ; il ne les lance pas au démarrage de Windows.

L'installateur conserve les autres paramètres `.wslconfig` et sauvegarde le
fichier avant modification. **S'il change, toutes les distributions WSL sont
arrêtées** pour appliquer le nouveau réseau. Les opérations Linux sont exécutées
en root via WSL, sans configurer d'utilisateur Linux ni de groupe Docker.

Une relance conserve le volume et réutilise un conteneur Portainer compatible.
Si un conteneur du même nom a une autre configuration, l'installateur s’arrête
sans le supprimer. Il refuse aussi de supprimer automatiquement des paquets
Docker concurrents. Une relance redémarre Docker et peut donc interrompre les
conteneurs déjà présents.

## IV. Utiliser l'installateur

### Arguments de l'installateur

Les quatre arguments sont facultatifs.

| Argument | Valeur par défaut | Utilité |
| --- | --- | --- |
| `-DistributionName` | `corpo_friendly_docker_ubuntu` | Nom de la distribution WSL a utiliser ou a créer si elle n'existe pas. Ce nom est repris dans le lanceur. |
| `-ProxyUrl` | `http://127.0.0.1:9000` | URL du proxy utilise par Ubuntu et Docker pour les connexions HTTP et HTTPS. |
| `-NoProxy` | `localhost,127.0.0.1` | Liste des hôtes ou domaines a joindre sans passer par le proxy, séparés par des virgules. Cette valeur remplace la liste par défaut. |
| `-CorporateCaCertificatePath` | Aucun certificat importé | Chemin Windows vers le certificat racine d'entreprise au format PEM, à ajouter aux autorités de confiance d'Ubuntu si l'inspection TLS le nécessite. |

### Prérequis

- Windows 11 avec la virtualisation disponible et **WSL 2**. La version
installée de WSL doit prendre en charge le mode réseau miroir,
`dnsTunneling`, `autoProxy`, systemd et `wsl --install --name`.
Si nécessaire, mettre WSL a jour avec `wsl --update`.
- PowerShell 5.1 ou ultérieur, ouvert avec le compte Windows qui utilisera WSL,
et droit d'écriture dans le dossier du projet.
- Proxy accessible depuis Ubuntu sur `http://127.0.0.1:9000` par défaut, accès
aux dépôts Ubuntu et Docker et a Docker Hub. Le projet ne fournit pas de
service proxy.
- Google Chrome pour le lanceur ; il n'est pas installe automatiquement.

Le script n'impose pas de droits administrateur Windows. L'activation de
composants Windows manquants peut toutefois nécessiter un administrateur et un
redémarrage ; aucune élévation automatique de privilège n'est effectuée.

### Installer

Depuis une session PowerShell normale, dans le dossier contenant les deux
scripts :

```powershell
.\Install-PortainerWorkspace.ps1
```

La distribution créée ou utilisée par défaut s'appelle
`corpo_friendly_docker_ubuntu` et contient Ubuntu 24.04. Une distribution
existante `Ubuntu-24.04` n'est pas modifiée par défaut. Pour l'utiliser :

```powershell
.\Install-PortainerWorkspace.ps1 -DistributionName 'Ubuntu-24.04'
```

Le nom choisi est repris dans le lanceur. L'installateur ne change pas la
distribution WSL par défaut.

Pour préciser un proxy et, si l'inspection TLS le nécessite, un certificat CA
d'entreprise **PEM** obtenu auprès de l’équipe informatique :

```powershell
.\Install-PortainerWorkspace.ps1 `
-ProxyUrl 'http://127.0.0.1:9000' `
-CorporateCaCertificatePath 'C:\Certificates\corporate-root.crt'
```

Le certificat est facultatif : sans ce paramètre, aucun certificat n'est importe.
Ne pas inclure d'identifiants dans l'URL du proxy ; la vérification TLS n'est
jamais désactivée.

#### Astuce : exporter le certificat CA d'entreprise depuis Chrome

1. Ouvrir dans Chrome un site HTTPS dont le trafic est soumis a l'inspection
TLS de l'entreprise.
2. A gauche de la barre d'adresse, ouvrir les informations du site, puis
**Connexion sécurisée** et **Le certificat est valide**. Les libelles peuvent
varier selon la version de Chrome.
3. Dans l'onglet **Détails**, sélectionner la racine d'entreprise en haut de la
chaîne de certificats, pas le certificat du site ni un intermédiaire.
4. Cliquer sur **Exporter** et choisir **X.509 encode en Base64 (PEM)**,
certificat seul (pas la chaîne complète). Le fichier doit contenir
`-----BEGIN CERTIFICATE-----` et `-----END CERTIFICATE-----`.
5. Avant de passer le fichier a `-CorporateCaCertificatePath`, comparer
l'empreinte SHA-256 du certificat exporte avec celle communiquée par
l’équipe informatique via un canal de confiance. Si la racine n’apparaît pas
dans Chrome ou si l'empreinte ne peut pas être confirmée, demander le
certificat directement a l’équipe informatique.

### Lancer et arreter

Depuis le dossier du projet :

```powershell
.\Start-DockerUI.ps1
```

Le dossier est aussi ajoute au PATH utilisateur pour permettre l'utilisation de
`Start-DockerUI.ps1` depuis un autre emplacement. Redémarrer le terminal ou se
déconnecter de Windows si le PATH n'est pas encore recharge. Si le projet est
déplacé, relancer l'installateur pour ajouter le nouvel emplacement ; l'ancien
n'est pas supprime automatiquement.

Créer rapidement le compte administrateur Portainer au premier lancement. Si le
délai de configuration initiale expire, redémarrer le conteneur et rouvrir
l'interface :

```powershell
wsl -d corpo_friendly_docker_ubuntu -u root -- docker restart portainer
```

Le lanceur maintient la distribution active après sa fermeture. Pour arrêter
**uniquement cette distribution et ses conteneurs**, sans arrêter les autres :

```powershell
wsl --terminate corpo_friendly_docker_ubuntu
```

Adapter le nom dans ces commandes si `-DistributionName` a été personnalise.
Le lanceur affiche également la commande d’arrêt après l'ouverture de Chrome.

### Depannage

- **Portainer inaccessible** : vérifier que la distribution, Docker et le
conteneur sont actifs. Utiliser `127.0.0.1` si `localhost` pose problème ;
le maintien de WSL ne contourne pas les restrictions réseau ou de sécurité.
- **DNS** : le script ne modifie pas `/etc/resolv.conf` et ne force pas de DNS
public. L'adresse du résolveur est gérée par WSL avec DNS tunneling.
- **Proxy ou TLS** : les variables HTTPS sont configurées explicitement. Les
sessions Linux déjà ouvertes doivent recharger le profil ou être rouvertes.
En cas d'erreur TLS, utiliser un certificat CA approuve plutôt que
désactiver la vérification.
- **Credential helper** : une erreur `secretservice`, `pass` ou `GDBus` peut
provenir d'une ancienne configuration Docker ou d'un PATH contamine par
Rancher Desktop. Les examiner sans les effacer automatiquement.