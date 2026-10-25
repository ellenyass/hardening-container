const obrigatorias = ["DB_HOST", "DB_PORT", "DB_USER", "DB_PASSWORD", "DB_NAME"];

console.log("Olá mundo!");

const ausentes = obrigatorias.filter((nome) => !process.env[nome]);

if (ausentes.length > 0) {
  console.error("Variáveis de ambiente ausentes: " + ausentes.join(", "));
  process.exit(1);
}

console.log(
  "Configuração carregada para o banco " +
    process.env.DB_NAME +
    " em " +
    process.env.DB_HOST +
    ":" +
    process.env.DB_PORT +
    "."
);
