#!/usr/bin/env bash

ask() {
	while true ; do
		if [[ -z $3 ]] ; then
			read -r -p "$1 [$2]: " result
		else
			read -r -p "$1 ($3) [$2]: " result
		fi
		if [[ -z $result ]]; then
			ask_result=$2
			return
		fi
		array=$3
		if [[ -z $3 || " ${array[*]} " =~ ${result} ]]; then
			ask_result=$result
			return
		else
			echo "Invalid option: $result"
		fi
	done
}

ask_docker_folder() {
	while true ; do

		read -r -p "$1 [$2]: " result

		if [[ -z $result ]]; then
			ask_result=$2
			return
		fi

		if [[ $result == /* || $result == ./* ]]; then
			ask_result=$result
			return
		else
			echo "Invalid folder: $result"
		fi

	done
}

if [[ $(id -u) == "0" ]] ; then
	echo "Do not run this script as root."
	exit 1
fi

if ! command -v wget &> /dev/null ; then
	echo "wget executable not found. Is wget installed?"
	exit 1
fi

if ! command -v docker &> /dev/null ; then
	echo "docker executable not found. Is docker installed?"
	exit 1
fi

if ! docker compose &> /dev/null ; then
	echo "docker compose plugin not found. Is docker compose installed?"
	exit 1
fi

# Check if user has permissions to run Docker by trying to get the status of Docker (docker status).
# If this fails, the user probably does not have permissions for Docker.
if ! docker stats --no-stream &> /dev/null ; then
	echo ""
	echo "WARN: It look like the current user does not have Docker permissions."
	echo "WARN: Use 'sudo usermod -aG docker $USER' to assign Docker permissions to the user (may require restarting shell)."
	echo ""
	sleep 3
fi

default_time_zone=$(timedatectl show -p Timezone --value)

set -e

URL=""
PORT="8000"
TIME_ZONE="$default_time_zone"
DATABASE_BACKEND="postgres"
TIKA_ENABLED="yes"
OCR_LANGUAGE="eng"
USERMAP_UID="1000"
USERMAP_GID="1000"
TARGET_FOLDER="$(pwd)/docucat"
CONSUME_FOLDER="$TARGET_FOLDER/consume"
MEDIA_FOLDER=""
DATA_FOLDER=""
DATABASE_FOLDER=""
USERNAME="docucat"

while true; do
	read -r -sp "Paperless password: " PASSWORD
	echo ""

	if [[ -z $PASSWORD ]] ; then
		echo "Password cannot be empty."
		continue
	fi

	read -r -sp "Paperless password (again): " PASSWORD_REPEAT
	echo ""

	if [[ ! "$PASSWORD" == "$PASSWORD_REPEAT" ]] ; then
		echo "Passwords did not match"
	else
		break
	fi
done

EMAIL="$USERNAME@localhost"

mkdir -p "$TARGET_FOLDER"

cd "$TARGET_FOLDER"

DOCKER_COMPOSE_VERSION=$DATABASE_BACKEND

if [[ $TIKA_ENABLED == "yes" ]] ; then
	DOCKER_COMPOSE_VERSION="$DOCKER_COMPOSE_VERSION-tika"
fi

wget "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/docker-compose.$DOCKER_COMPOSE_VERSION.yml" -O docker-compose.yml
wget "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/.env" -O .env

SECRET_KEY=$(LC_ALL=C tr -dc 'a-zA-Z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | dd bs=1 count=64 2>/dev/null)


DEFAULT_LANGUAGES=("deu eng fra ita spa")

_split_langs="${OCR_LANGUAGE//+/ }"
read -r -a OCR_LANGUAGES_ARRAY <<< "${_split_langs}"

{
	if [[ ! $URL == "" ]] ; then
		echo "PAPERLESS_URL=$URL"
	fi
	if [[ ! $USERMAP_UID == "1000" ]] ; then
		echo "USERMAP_UID=$USERMAP_UID"
	fi
	if [[ ! $USERMAP_GID == "1000" ]] ; then
		echo "USERMAP_GID=$USERMAP_GID"
	fi
	echo "PAPERLESS_TIME_ZONE=$TIME_ZONE"
	echo "PAPERLESS_OCR_LANGUAGE=$OCR_LANGUAGE"
	echo "PAPERLESS_SECRET_KEY=$SECRET_KEY"
	if [[ ! ${DEFAULT_LANGUAGES[*]} =~ ${OCR_LANGUAGES_ARRAY[*]} ]] ; then
		echo "PAPERLESS_OCR_LANGUAGES=${OCR_LANGUAGES_ARRAY[*]}"
	fi
} > docker-compose.env

sed -i "s/- \"8000:8000\"/- \"$PORT:8000\"/g" docker-compose.yml

sed -i "s#- \./consume:/usr/src/paperless/consume#- $CONSUME_FOLDER:/usr/src/paperless/consume#g" docker-compose.yml

if [[ -n $MEDIA_FOLDER ]] ; then
	sed -i "s#- media:/usr/src/paperless/media#- $MEDIA_FOLDER:/usr/src/paperless/media#g" docker-compose.yml
	sed -i "/^\s*media:/d" docker-compose.yml
fi

if [[ -n $DATA_FOLDER ]] ; then
	sed -i "s#- data:/usr/src/paperless/data#- $DATA_FOLDER:/usr/src/paperless/data#g" docker-compose.yml
	sed -i "/^\s*data:/d" docker-compose.yml
fi

# If the database folder was provided (not blank), replace the pgdata/dbdata volume with a bind mount
# of the provided folder
if [[ -n $DATABASE_FOLDER ]] ; then
	if [[ "$DATABASE_BACKEND" == "postgres" ]] ; then
		sed -i "s#- pgdata:/var/lib/postgresql/data#- $DATABASE_FOLDER:/var/lib/postgresql/data#g" docker-compose.yml
		sed -i "/^\s*pgdata:/d" docker-compose.yml
	elif [[ "$DATABASE_BACKEND" == "mariadb" ]]; then
		sed -i "s#- dbdata:/var/lib/mysql#- $DATABASE_FOLDER:/var/lib/mysql#g" docker-compose.yml
		sed -i "/^\s*dbdata:/d" docker-compose.yml
	fi
fi

# remove trailing blank lines from end of file
sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' docker-compose.yml
# if last line in file contains "volumes:", remove that line since no more named volumes are left
l1=$(grep -n '^volumes:' docker-compose.yml | cut -d : -f 1)  # get line number containing volume: at begin of line
l2=$(wc -l < docker-compose.yml)  # get total number of lines
if [ "$l1" -eq "$l2" ] ; then
	sed -i "/^volumes:/d" docker-compose.yml
fi


docker compose pull

if [ "$DATABASE_BACKEND" == "postgres" ] || [ "$DATABASE_BACKEND" == "mariadb" ] ; then
	echo "Starting DB first for initialization"
	docker compose up --detach db
	# hopefully enough time for even the slower systems
	sleep 15
	docker compose stop
fi

docker compose run --rm -e DJANGO_SUPERUSER_PASSWORD="$PASSWORD" webserver createsuperuser --noinput --username "$USERNAME" --email "$EMAIL"

docker compose up --detach
