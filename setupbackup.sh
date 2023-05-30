PSQLVERSION="15"
DBUSER="taccarlo"
DBPASSWORD="taccarlo"
DBNAME="taccarli"

#installazione psql
function setupdb(){
	apt update && apt upgrade -y
	sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
	wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
	apt update
	apt-get -y install postgresql-$PSQLVERSION
	systemctl start postgresql
}

#creazione db e utente amministratore
function createdb(){
	sudo -u postgres psql <<END
    CREATE USER $DBUSER WITH PASSWORD '$DBPASSWORD';
    CREATE DATABASE $DBNAME;
    ALTER DATABASE $DBNAME OWNER TO $DBUSER;
    GRANT ALL PRIVILEGES ON DATABASE $DBNAME TO $DBUSER;
    GRANT CREATE ON SCHEMA public to $DBUSER;
END
}

function createTable(){
	sudo -u postgres psql -d $DBNAME <<END
	CREATE TABLE [IF NOT EXISTS] login(
		id int SERIAL NOT NULL,
		user varchar(255) NOT NULL,
		password varchar(255) NOT NULL,
		PRIMARY KEY (id)
	);
END
}
