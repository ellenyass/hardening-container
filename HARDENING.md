# Hardening de containers

Diagnóstico da configuração inicial, medidas aplicadas e evidências de que a aplicação continua funcionando.

## 1. Problemas encontrados

A construção original foi executada antes das alterações. Ela falhou em `RUN npm install` com `ENOENT: no such file or directory, open '/app/package.json'`. Antes dessa falha, o `apt-get install -y nodejs npm` já instalava um conjunto grande de pacotes que a aplicação não usa, entre eles `gcc`, `g++`, `build-essential`, `git`, `python3`, `eslint` e `webpack`.

| Problema | Onde | Risco |
| --- | --- | --- |
| Base `ubuntu:latest`, sem versão fixa | `Dockerfile` | A tag `latest` muda sem aviso. A imagem traz shell, `apt` e um sistema completo, com mais componentes e mais CVEs do que o runtime da aplicação exige. |
| `nodejs` e `npm` instalados pelo `apt`, em camadas separadas e sem limpeza | `Dockerfile` | Entram compilador, Git, Python e centenas de pacotes. Isso aumenta a superfície de ataque e o tamanho da imagem. Camadas de `apt-get update` separadas também envelhecem o índice de pacotes. |
| `npm install` sem `package.json` e `COPY . .` | `Dockerfile` | O build não gera imagem utilizável. O contexto inteiro, incluindo documentação e arquivos que não são da aplicação, seria copiado para a imagem. |
| `ENV DB_PASSWORD=123456` | `Dockerfile` | A senha fica gravada na camada e no histórico da imagem. Quem obtiver a imagem lê o segredo com `docker history` ou `docker inspect`, mesmo que a aplicação funcione. |
| Nenhum `USER`; processo padrão é root | `Dockerfile` | Um comprometimento da aplicação acontece com privilégio administrativo dentro do container. |
| `mysql:latest` e `MYSQL_ROOT_PASSWORD: root` | `docker-compose.yml` | A tag não é reproduzível. A senha de administrador é fraca e fica no arquivo versionado. |
| Porta `3306:3306` publicada | `docker-compose.yml` | O banco, usado só pela aplicação, fica acessível na máquina hospedeira e, por padrão, em todas as interfaces. |
| Sem limite de CPU, memória ou processos | `docker-compose.yml` | Um container pode consumir os recursos do host e prejudicar os demais serviços. |
| Sem `cap_drop`, `no-new-privileges` ou sistema de arquivos somente leitura | `docker-compose.yml` | O container conserva capacidades do Linux e pode alterar o próprio sistema de arquivos. |
| Sem `.gitignore` e sem separação de segredos | repositório | Não havia barreira para impedir o versionamento de um arquivo com senhas. |

A aplicação em si só executava `console.log("Olá mundo!")`. Ela não abre porta e não precisa de dependências npm. A porta 3000 publicada no serviço `app` é a interface prevista para a aplicação web. A porta 3306 não precisa sair do host.

## 2. Medidas aplicadas

### Imagem

O `Dockerfile` passou a usar `node:22.23.4-alpine3.24`, com digest fixo. A imagem oficial já contém o runtime Node.js. Não há `apt-get`, não há `npm install` e o `COPY` envia apenas `app/server.js`. Um `.dockerignore` deixa `.env`, documentação e o Compose fora do contexto de build. O contexto transferido na construção mediu 545 bytes.

Uma imagem menor reduz a superfície de ataque porque há menos binários, bibliotecas e serviços que um atacante pode abusar. Também há menos vulnerabilidades conhecidas para corrigir, e a ausência de compilador e de gerenciador de pacotes dificulta instalar ferramentas depois de um comprometimento.

### Menor privilégio

A imagem declara `USER node`. O usuário `node` (uid 1000) já existe na imagem oficial e só precisa ler o código e executá-lo.

O container da aplicação também usa `cap_drop: ALL`, `no-new-privileges:true`, `read_only: true` e um `tmpfs` em `/tmp`. O processo não é privilegiado.

No banco, a imagem oficial precisa iniciar o entrypoint como root para, em seguida, trocar para o usuário `mysql`. O processo `mysqld` fica com uid 999. Foram removidas todas as capabilities e devolvidas só as necessárias para essa troca e para ajustar os arquivos do datadir: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID` e `SETUID`. O protocolo MySQL X, na porta interna 33060, foi desligado com `--mysqlx=0` porque a aplicação usa apenas a porta 3306.

A conta de administração do MySQL não é mais a conta da aplicação. O Compose cria o usuário `app`, com acesso ao schema `sistema`. A variável `MYSQL_ROOT_PASSWORD` entra somente no serviço `banco`. O container da aplicação recebe `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` e `DB_NAME`.

Se um atacante controlar uma aplicação que roda como root no container, ele pode alterar arquivos do container, instalar ferramentas, ler segredos do ambiente e tentar um escape com mais chance de sucesso. No Docker padrão, o root do container corresponde ao root do host em várias operações. Com capabilities extras, volume do socket do Docker ou `privileged`, esse controle vira controle do host. Com o usuário `node`, sem capabilities e com o sistema de arquivos somente leitura, o mesmo comprometimento fica restrito ao que a aplicação já podia fazer.

### Segredos

As senhas saíram do `Dockerfile`, do `docker-compose.yml` e do código. Os valores locais ficam em `.env`, que o `.gitignore` ignora. O `.env.example` lista apenas os nomes, com valores vazios:

```env
DB_USER=
DB_PASSWORD=
DB_NAME=
MYSQL_ROOT_PASSWORD=
```

O Compose interpola `${DB_PASSWORD}` e `${MYSQL_ROOT_PASSWORD}` e interrompe a subida se alguma variável obrigatória estiver ausente. `app/server.js` continua imprimindo `Olá mundo!` e encerra com erro se as variáveis não chegarem ao processo. O código não contém a senha e não a imprime.

Guardar a senha no `Dockerfile` é um risco mesmo com a aplicação funcionando, porque o valor vira parte permanente da imagem. Ele aparece no histórico de camadas, em caches de CI e no registry. Apagar a variável numa camada posterior não remove a camada anterior. Trocar a senha exige reconstruir e redistribuir a imagem, e qualquer cópia antiga continua válida.

O `.env` não deve ir para o repositório porque contém os valores reais. O histórico do Git é clonado, espelhado e muitas vezes permanece depois que o arquivo é removido. Quem acessa o repositório passaria a conhecer as credenciais.

O `.env.example` documenta quais variáveis são necessárias para outra pessoa criar o próprio `.env`, sem receber os segredos.

A diferença para uma senha escrita no `docker-compose.yml` é o lugar em que o valor existe. No arquivo Compose versionado, a senha acompanha o projeto. Na forma `${DB_PASSWORD}`, o arquivo versionado guarda só o nome. O valor fica no `.env` local e é injetado quando os containers sobem.

### Rede

Os dois serviços usam a rede `interna`. A aplicação publica somente `127.0.0.1:3000:3000`. O banco não tem `ports`. Ele continua acessível pelo nome `banco`, na porta 3306, para containers dessa rede.

Não há motivo para publicar a porta de um banco usado apenas pela aplicação. Na rede do Compose, o serviço `app` já alcança `banco:3306`. Publicar `3306` no host expõe o MySQL a outros processos da máquina e, no mapeamento original `3306:3306`, às interfaces de rede do host. Isso permite tentativa de senha e exploração direta do banco, sem passar pela aplicação.

### Recursos

Cada serviço tem limite de CPU, memória e número de processos:

| Serviço | CPU | Memória | Processos |
| --- | --- | --- | --- |
| `app` | 0,50 | 128 MB | 64 |
| `banco` | 0,50 | 512 MB | 200 |

Se um container puder consumir toda a CPU ou a memória do host, os outros processos passam a disputar o que sobrou. A latência sobe, o kernel pode encerrar processos pelo OOM killer e os serviços vizinhos ficam indisponíveis. O limite corta esse efeito no cgroup do container.

### Isolamento

Nenhum serviço usa `privileged`, `network_mode: host`, `pid: host` ou o socket do Docker. O sistema de arquivos raiz é somente leitura. O MySQL grava os dados no volume `mysql_data` e os arquivos temporários em `tmpfs`. O diretório do socket ficou em `drwxr-x---`, dono `mysql:mysql`, para não ficar gravável por qualquer usuário do container.

## 3. Análise final

1. **Qual era o principal risco encontrado no projeto?** O banco estava publicado no host com a senha de root `root` escrita no `docker-compose.yml`. Essa combinação já era explorável por qualquer processo que alcançasse a porta 3306, sem precisar de uma falha na aplicação. A imagem da aplicação ampliava o impacto: rodaria como root e levaria `DB_PASSWORD=123456` gravada na camada.

2. **Qual alteração de hardening foi mais importante? Por quê?** Deixar de publicar a porta do MySQL e tirar as senhas do Git e da imagem. Era o caminho de ataque que existia antes de qualquer comprometimento da aplicação. As demais medidas limitam o que um atacante consegue fazer depois de entrar.

3. **O que poderia acontecer caso o container da aplicação fosse comprometido?** O processo está como `node`, sem capabilities, sem ganho de privilégio e com o sistema de arquivos raiz somente leitura. O atacante não administra o host a partir desse usuário e não recebe `MYSQL_ROOT_PASSWORD`. Ele ainda pode ler `DB_PASSWORD` no ambiente do processo e falar com o MySQL como o usuário `app`, restrito ao schema `sistema`. O dano fica nos dados dessa aplicação. Os limites de CPU, memória e processos impedem que esse container esgote o host sozinho.

4. **Como o princípio do menor privilégio foi aplicado?** A aplicação usa o usuário `node` e perde todas as capabilities. O banco executa o `mysqld` como `mysql` e recebe só as capabilities usadas pelo entrypoint oficial. A aplicação não recebe a senha de root. O usuário `app` existe para o schema `sistema`. Na rede, só a porta 3000 da aplicação é publicada, e apenas em `127.0.0.1`. Cada container tem teto de CPU, memória e processos.

5. **Por que o `.env` não deve ser enviado para o repositório?** Porque ele contém os valores reais das senhas. O Git replica esses valores para todo clone e os mantém no histórico.

6. **Qual é a função do `.env.example`?** Mostrar os nomes das variáveis obrigatórias, sem os segredos, para que o ambiente local possa ser recriado.

7. **Como o projeto poderia receber novas verificações de segurança automaticamente em uma pipeline CI/CD?** A pipeline pode reconstruir a imagem a cada alteração e bloquear o merge quando uma verificação falhar. As verificações cabíveis aqui são análise do `Dockerfile` (Hadolint), varredura de vulnerabilidades da imagem (Trivy, Grype ou Docker Scout), geração de SBOM, busca de segredos no repositório (Gitleaks ou TruffleHog) e checagem de que o `.env` não foi commitado. A tag e o digest da base podem ser atualizados por um bot de dependências, com a pipeline falhando diante de CVE crítica. A imagem publicada pode ser assinada (Cosign) e identificada pelo digest, não por `latest`.

8. **Quais medidas adicionais poderiam ser aplicadas caso essa aplicação fosse executada em Kubernetes?** O equivalente direto está no `securityContext`: `runAsNonRoot`, `runAsUser`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]` e `seccompProfile: RuntimeDefault`. Uma `NetworkPolicy` deixaria o banco acessível só pelos pods da aplicação. O Service do MySQL seria `ClusterIP`; só a aplicação teria Ingress. Requests e limits, além de `LimitRange` e `ResourceQuota`, repetiriam o controle de CPU e memória. As senhas iriam para Secret, de preferência provido por um operador de segredos externos, e não para um ConfigMap ou para o Git. A política de admissão `restricted` (Pod Security Admission), RBAC mínimo, proibição de `hostPath`, `hostNetwork` e `hostPID`, e imagens referenciadas por digest completam o mesmo princípio neste orquestrador.

## 4. Evidências da validação

Comandos executados depois do hardening, no diretório do projeto.

A aplicação encerra com sucesso e confirma que leu a configuração, sem imprimir senha:

```text
docker compose logs app
app-1  | Olá mundo!
app-1  | Configuração carregada para o banco sistema em banco:3306.
```

O container da aplicação terminou com código 0. O banco ficou `healthy`.

Usuário da aplicação:

```text
docker compose run --rm --no-deps --entrypoint id app
uid=1000(node) gid=1000(node) groups=1000(node)

docker compose run --rm --no-deps --entrypoint whoami app
node
```

Usuário do processo do banco:

```text
mysqld
Uid: 999 999 999 999
/var/run/mysqld  drwxr-x--- mysql mysql
```

O entrypoint registrou `Switching to dedicated user 'mysql'`, criou o schema `sistema` e o usuário `app`.

Variáveis efetivas da aplicação, só os nomes:

```text
DB_HOST, DB_NAME, DB_PASSWORD, DB_PORT, DB_USER
```

`MYSQL_ROOT_PASSWORD` não está nesse conjunto. Na configuração resolvida do Compose, essa variável aparece apenas no serviço `banco`. A imagem `hardening-container-app` declara `User=node` e o histórico não contém `DB_PASSWORD` nem `apt-get`. O tamanho da imagem ficou em 239.072.790 bytes (228 MB).

Isolamento e limites lidos com `docker inspect`:

| Verificação | `app` | `banco` |
| --- | --- | --- |
| Memória | 134217728 (128 MB) | 536870912 (512 MB) |
| CPU (`NanoCpus`) | 500000000 (0,50) | 500000000 (0,50) |
| Processos | 64 | 200 |
| Sistema de arquivos somente leitura | verdadeiro | verdadeiro |
| `Privileged` | falso | falso |
| `CapDrop` | `ALL` | `ALL` |
| `no-new-privileges` | sim | sim |
| Portas publicadas | `127.0.0.1:3000` | nenhuma |

A conexão TCP com `127.0.0.1:3306` no host falhou (`host-3306=fechada`). Um container novo da aplicação, na rede `interna`, conectou em `banco:3306` (`banco-acessivel-na-rede-interna`).

O Git ignora o `.env`:

```text
git check-ignore -v .env
.gitignore:1:.env	.env
```

`git status` não lista o `.env`.

## Como executar

Com o Docker em execução, na raiz do projeto:

```text
copy .env.example .env
```

Preencha `.env` com os valores locais. O arquivo já existe nesta máquina e não deve ser commitado. Em seguida:

```text
docker compose up -d
docker compose ps -a
docker compose logs app
```

Para encerrar os containers e conservar os dados do banco:

```text
docker compose down
```
