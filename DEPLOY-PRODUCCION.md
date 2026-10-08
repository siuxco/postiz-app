# Deploy de Postiz a producción

Instructivo para dejar Postiz corriendo en el servidor (Portainer), con el mismo esquema que siux.co y siux.studio. Los archivos subidos van al **MinIO del servidor**, como en tarotia.app.

Archivos preparados (sin commit todavía):

- `docker-compose.prod.yml`: stack para Portainer. Solo descarga imágenes, no construye.
- `.env.prod.example`: variables a cargar en Portainer.
- `.github/workflows/siux-build.yaml`: construye la imagen del fork y avisa a Portainer.
- `Dockerfile.siux` y `var/docker/siux-start.sh`: la imagen de Postiz (`Dockerfile.dev`, sin tocar) más Redis y Temporal embebidos. Si `REDIS_URL` o `TEMPORAL_ADDRESS` apuntan a otro host, usa ese y no levanta el propio.
- Cambio de código en `libraries/nestjs-libraries/src/upload/cloudflare.storage.ts` y `r2.uploader.ts`: variable opcional `CLOUDFLARE_ENDPOINT` para usar un S3 compatible (MinIO) en lugar de R2. Sin esa variable el comportamiento es el de siempre.

**Por qué hace falta un fork:** Postiz solo sabe guardar en disco local o en Cloudflare R2, con el endpoint de R2 fijo en el código. Para MinIO hubo que tocar el código, así que la imagen oficial de gitroomhq no sirve: se construye una propia (`ghcr.io/siuxco/postiz-app`).

Con producción ya no hacen falta el túnel de Cloudflare ni la PC prendida: Instagram y TikTok bajan los archivos desde MinIO.

---

## 0. Antes de empezar

Decidir o tener a mano:

1. **Dominio de Postiz.** Ejemplo: `postiz.siux.co`. En este documento uso ese.
2. **Postgres del servidor.** Crear una base y un usuario propios de Postiz y armar `DATABASE_URL` (`postgresql://postiz:<clave>@<host>:5432/postiz`). La clave en hex: caracteres como `@ : / #` rompen la URL. Prisma crea las tablas en el primer arranque.
3. **MinIO de tarotia.app.** Postiz usa las mismas variables (`MINIO_ENDPOINT`, `MINIO_PORT`, `MINIO_USE_SSL`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_BUCKET_NAME`) con la conexión interna: `MINIO_PORT=9000`, sin SSL. Bucket y claves propios.
4. **Red de Docker compartida (`SHARED_NETWORK`).** La red donde están Postgres y MinIO, para que Postiz los alcance por nombre. Verla con `docker network ls` / `docker inspect <contenedor-minio>`.
5. **URL pública de MinIO (`MINIO_PUBLIC_URL`).** Un hostname https que el proxy mande a MinIO:9000, ej. `https://s3.sv00.siux.co`. Hace falta aunque Postiz use la conexión interna: ver el paso 2.
6. **Cuándo.** Hacerlo **después del domingo 11/10 19:00**, cuando salga el último post programado en el Postiz local.
7. **Datos.** Arrancar limpio (recomendado) o migrar los datos del local (ver el paso 9).

---

## 1. Fork y build de la imagen

1. En GitHub: fork de `gitroomhq/postiz-app` en la organización **siuxco** → `siuxco/postiz-app`.
2. En la copia local, apuntar al fork y subir los cambios:

   ```bash
   git remote rename origin upstream
   git remote add origin https://github.com/siuxco/postiz-app.git
   git checkout -b siux
   git add docker-compose.prod.yml .env.prod.example DEPLOY-PRODUCCION.md \
     .github/workflows/siux-build.yaml \
     libraries/nestjs-libraries/src/upload/cloudflare.storage.ts \
     libraries/nestjs-libraries/src/upload/r2.uploader.ts
   git commit -m "feat: deploy siux con MinIO (CLOUDFLARE_ENDPOINT)"
   git push -u origin siux
   ```

   No commitear `docker-compose.yaml`: es el del entorno local y tiene credenciales.
3. En el fork → **Actions**: deshabilitar **"Build Containers"** (`build-containers.yml`). Corre con cada tag y falla porque intenta pushear a `ghcr.io/gitroomhq`.
4. Construir la primera imagen: Actions → **Siux Build** → *Run workflow* sobre la rama `siux`, o crear un tag (`git tag v2.25.0-siux.1 && git push origin v2.25.0-siux.1`). Queda en `ghcr.io/siuxco/postiz-app:latest`.
5. El paquete de GHCR queda privado por defecto: darle acceso al registry que usa Portainer (igual que con `siux.co`) o hacerlo público.
6. Para traer actualizaciones de Postiz más adelante: `git fetch upstream && git merge upstream/main` en la rama `siux`, y volver a construir.

## 2. Bucket en MinIO

Con `mc` (el cliente de MinIO) configurado contra el MinIO del servidor como alias `siux`:

```bash
mc mb siux/postiz
# Lectura anónima: Instagram y TikTok bajan los archivos sin credenciales
mc anonymous set download siux/postiz
```

**Usuario de acceso:** crear un access key solo para Postiz, limitado a ese bucket (MinIO → Access Keys, con una policy de lectura y escritura sobre `postiz/*`). No reutilizar la clave root.

**Endpoint público:** el backend habla con MinIO por la red interna (`http://MINIO_ENDPOINT:MINIO_PORT`), pero el navegador sube los videos directo a MinIO con URLs firmadas, e Instagram y TikTok bajan los archivos desde internet. Por eso hace falta `MINIO_PUBLIC_URL`: un Proxy Host en Nginx Proxy Manager (ej. `s3.sv00.siux.co` → `http://minio:9000`, con Let's Encrypt) que **conserve el header `Host`** (NPM lo hace por defecto), porque la firma lo incluye. Los archivos quedan en `MINIO_PUBLIC_URL/MINIO_BUCKET_NAME/<archivo>`.

En NPM, para que los videos grandes no corten: en *Advanced* del proxy host, `client_max_body_size 0;` y `proxy_request_buffering off;`.

**CORS:** MinIO tiene que aceptar el origen de Postiz para `PUT` y exponer el header `ETag` (MinIO lo expone por defecto; sin él, la subida multiparte no puede completarse):

```bash
mc admin config set siux api cors_allow_origin="https://postiz.siux.co,https://tarotia.app"
mc admin service restart siux
```

Esta configuración es global, así que incluir los orígenes que ya use tarotia.app. Si tarotia ya tiene CORS configurado, sumar `https://postiz.siux.co` a esa lista.

**Lectura pública:** el `ACL: public-read` que manda Postiz no tiene efecto en MinIO; lo que hace públicos los archivos es la policy anónima del bucket (`mc anonymous set download`).

Comprobar que la URL pública responde, por ejemplo subiendo un archivo de prueba y abriéndolo en `MINIO_PUBLIC_URL/postiz/<archivo>`.

## 3. DNS

En Cloudflare, zona `siux.co`: crear el registro `postiz` apuntando al servidor, igual que el resto de los subdominios de siux.

## 4. Generar secretos

```bash
openssl rand -hex 32   # JWT_SECRET
openssl rand -hex 24   # clave del usuario postiz en Postgres (va en DATABASE_URL)
```

Guardarlos en el gestor de contraseñas. **Si se pierde `JWT_SECRET` se cierran todas las sesiones; si se pierden las contraseñas de las bases, no se puede volver a levantar el stack con los datos existentes.**

## 5. Crear el stack en Portainer

1. Portainer → Stacks → **Add stack** → nombre `postiz` → *Repository*: `siuxco/postiz-app`, rama `siux`, archivo `docker-compose.prod.yml` (o pegar el archivo en el editor web).
2. **Environment variables** (ver `.env.prod.example`):

| Variable | Valor |
|---|---|
| `POSTIZ_URL` | `https://postiz.siux.co` (tiene que ser https) |
| `JWT_SECRET` | el generado |
| `DATABASE_URL` | `postgresql://postiz:<clave>@<host>:5432/postiz` |
| `SHARED_NETWORK` | `backend_net` (valor por defecto) |
| `MINIO_ENDPOINT` | host interno de MinIO, como en tarotia, ej. `minio` |
| `MINIO_PORT` | `9000` |
| `MINIO_USE_SSL` | `false` |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | el access key del paso 2 |
| `MINIO_BUCKET_NAME` | `postiz` |
| `MINIO_PUBLIC_URL` | URL https pública de MinIO, sin barra final, ej. `https://s3.sv00.siux.co` |
| `POSTIZ_PORT` | `5000`, u otro si está ocupado en el host |
| `FACEBOOK_APP_ID` | `1833939861360105` (app "Postiz" en Meta) |
| `FACEBOOK_APP_SECRET` | Meta for Developers → Postiz → Información básica |

   **Dejar `EMAIL_PROVIDER` vacío** hasta tener `RESEND_API_KEY` y `EMAIL_FROM_ADDRESS`: con un proveedor configurado y sin clave, Postiz pide activar la cuenta por email y el primer usuario no puede entrar.
3. **Deploy the stack.** El primer arranque tarda unos minutos: Temporal (embebido en la imagen, base SQLite en `/config/temporal.db`) crea su base y Postiz su esquema. El contenedor `postiz` pasa a `healthy` cuando responde.
4. **Webhook:** en el stack, activar *Webhook* y copiar la URL. En el fork → Settings → Variables → `PORTAINER_WEBHOOK`. Desde entonces, cada build redeploya solo.

## 6. Proxy con TLS (Nginx Proxy Manager)

Crear un *Proxy Host*:

- Domain: `postiz.siux.co` → Forward: `http://<host>:5000` (o el `POSTIZ_PORT` elegido).
- SSL: certificado Let's Encrypt, *Force SSL*.
- En **Advanced**:

  ```nginx
  client_max_body_size 1024m;
  proxy_read_timeout 300s;
  ```

`https://postiz.siux.co` debería mostrar el login de Postiz.

## 7. Primer usuario y prueba de subida

1. Registrarse en `https://postiz.siux.co`. Con la base vacía Postiz permite registrar el primer usuario aunque `DISABLE_REGISTRATION=true`. Después nadie más puede registrarse; para sumar gente, invitarla desde Postiz.
2. Subir una imagen y un video en la biblioteca de medios. Comprobar:
   - que aparecen en el bucket `postiz` de MinIO;
   - que se abren desde `https://MINIO_ENDPOINT/postiz/<archivo>` en una ventana privada (sin sesión);
   - que no se achican: la imagen tiene que quedar en su tamaño original (`DISABLE_IMAGE_COMPRESSION=true`).

   Si la subida del video falla en el navegador, revisar CORS (paso 2).

## 8. Reconectar las redes

**Instagram (Meta, app "Postiz"):**
1. Meta for Developers → Postiz → Inicio de sesión con Facebook para empresas → Configuración → **URI de redireccionamiento de OAuth válidos**: agregar `https://postiz.siux.co/integrations/social/instagram` y guardar.
2. Configuración de la aplicación → Información básica → **Dominios de la aplicación**: agregar `postiz.siux.co`.
3. En Postiz: Add Channel → Instagram (Facebook Business) → autorizar → elegir la página.
4. La app sigue en modo desarrollo: funciona para las cuentas con rol en la app. Para cuentas de terceros hay que pasarla a modo Live y pedir revisión de permisos.

**TikTok** (ver también `~/Downloads/tarotia-exports/PENDIENTES.md`):
1. En la app Tarotia → Sandbox → Login Kit: redirect `https://postiz.siux.co/integrations/social/tiktok`.
2. Cargar en Portainer `TIKTOK_CLIENT_ID` y `TIKTOK_CLIENT_SECRET` **del Sandbox** y redeployar.
3. Para carruseles de fotos, TikTok tiene que tener verificado el origen de los archivos: en URL properties, verificar el dominio `siux.co` (cubre el subdominio de MinIO) o el prefijo `MINIO_PUBLIC_URL/postiz/`.

## 9. (Opcional) Migrar datos del local

Solo si se quiere conservar el historial. **Los posts programados no se migran solos:** su programación vive en Temporal, que arranca vacío en producción. Hay que reprogramarlos desde la interfaz. Los archivos del local tampoco se migran: sus URLs apuntan al túnel.

```bash
# En la Mac
docker exec postiz-postgres pg_dump -U postiz-user -d postiz-db-local -Fc > postiz.dump

# Contra el Postgres del servidor (stack creado, contenedor postiz detenido)
pg_restore -d "$DATABASE_URL" --clean --if-exists --no-owner postiz.dump
```

## 10. Apagar lo provisorio en la Mac

Cuando producción funcione y ya no queden posts pendientes en el local:

```bash
pkill -f "cloudflared tunnel --no-autoupdate --url http://localhost:4007"
pkill -f "caffeinate -dimsu"
```

En `docker-compose.yaml` local: volver `MAIN_URL`, `FRONTEND_URL` y `NEXT_PUBLIC_BACKEND_URL` a `http://localhost:4007` y quitar `NOT_SECURED`, o bajar el stack local con `docker compose down`, que conserva los volúmenes.

## 11. Mantenimiento

- **Deploy de cambios:** push a la rama `siux` + tag de versión (o *Run workflow*). El webhook redeploya solo.
- **Actualizar Postiz:** `git fetch upstream && git merge upstream/main` en `siux`, resolver conflictos (los cambios propios son solo los archivos de este deploy y los dos de `upload/`), tag y build.
- **Backups:** la base `postiz` en el Postgres del servidor (sumarla a sus backups), el volumen `postiz-config` (tiene `temporal.db`, con los posts programados) y el bucket `postiz` en MinIO.
