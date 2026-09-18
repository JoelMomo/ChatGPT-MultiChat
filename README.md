# ChatGPT MultiChat

Gestor portable para Windows pensado para cuando **varios chats de ChatGPT usan Desktop Commander sobre el mismo PC al mismo tiempo**.

Su objetivo es reducir colisiones: cada chat obtiene una sesión identificable, un slot de color, un espacio de trabajo aislado cuando procede, un puerto de desarrollo propio y locks para recursos que no deberían usarse de forma concurrente.

> Estado actual: **v2.0.0**. Probado con el `SelfTest.ps1` incluido.

## El problema que resuelve

Si varios chats ejecutan comandos locales de forma independiente, pueden terminar:

- modificando el mismo repositorio a la vez;
- usando el mismo puerto de desarrollo;
- intentando usar ADB, fastboot, scrcpy o un emulador Android simultáneamente;
- dejando shells o sesiones huérfanas difíciles de distinguir;
- sobrescribiendo cambios de otro chat.

MultiChat convierte ese trabajo en sesiones coordinadas.

## Cómo funciona

```text
ChatGPT A ─┐
ChatGPT B ─┼─> Start-McpChatSession.ps1
ChatGPT C ─┘          │
                      ├─ asigna CHAT-1 ... CHAT-8
                      ├─ registra estado y actividad
                      ├─ crea worktree/branch aislados si corresponde
                      ├─ reserva un puerto de desarrollo
                      ├─ aplica locks de recursos compartidos
                      └─ aparece en el panel MultiChat
```

Cada chat debe abrir **una sola sesión persistente** y reutilizar su PID durante todo el trabajo. Los comandos posteriores se envían a esa misma sesión.

## Funciones principales

- Hasta **8 chats simultáneos**, cada uno con color fijo.
- Worktrees y ramas Git aislados por chat cuando se trabaja sobre un repositorio.
- Reserva automática de puertos de desarrollo.
- Locks configurables para recursos compartidos.
- Detección de actividad: `READY`, `BUILD`, `TEST`, `GIT`, `ADB`, `SERVER`, `WAIT`, etc.
- Panel WinForms ligero con refresco en tiempo real.
- Historial corto de sesiones terminadas.
- Detección y limpieza segura de worktrees ya terminados.
- Recuperación de sesiones abandonadas o procesos desaparecidos.
- Desktop Commander puede relanzarse oculto si deja de estar disponible.
- Sin arranque automático: solo se ejecuta cuando tú lo abres.
- Paquete portable sin rutas personales.

## Requisitos

- Windows 10/11.
- Windows PowerShell 5.1 o superior.
- Git.
- Node.js con `npx`.
- Desktop Commander remoto disponible mediante `npx`.

## Instalación rápida

1. Descarga el ZIP portable de la última release.
2. Descomprímelo en una carpeta permanente.
3. Ejecuta `Setup.cmd`.
4. Se creará el acceso directo **ChatGPT MultiChat Agent** en el escritorio.
5. Abre el agente antes de empezar a trabajar con varios chats.

`Setup.cmd` no configura inicio automático.

## Cómo usarlo con ChatGPT

La forma más simple es copiar al chat el contenido de `PROMPT-PARA-CHATGPT.txt`.

La instrucción esencial es:

```text
Usa el sistema ChatGPT MultiChat instalado en este PC para cualquier trabajo con Desktop Commander.
Inicia una sola sesión persistente con Start-McpChatSession.ps1, reutiliza su PID durante todo
el trabajo y no modifiques el proyecto mediante shells MCP sueltas.
```

El chat debería iniciar una sesión similar a esta:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\ruta\a\ChatGPT-MultiChat\Start-McpChatSession.ps1" `
  -ProjectPath "C:\ruta\al\proyecto" `
  -Task "descripcion-corta"
```

A partir de ahí, todos los comandos de ese trabajo deben enviarse al **mismo PID**.

Para una sesión que no deba crear worktree puede usarse:

```powershell
Start-McpChatSession.ps1 -ProjectPath "C:\ruta\al\proyecto" -Task "test" -NoWorktree
```

Al escribir `exit` o `quit`, la sesión se libera correctamente.

## El panel

El panel muestra por sesión:

| Campo | Significado |
|---|---|
| Chat | Slot asignado (`CHAT-1` ... `CHAT-8`) |
| Proyecto | Proyecto asociado |
| Actividad | `LIBRE`, `TRABAJANDO` o `ABANDONADO` |
| Detalle | Tipo de trabajo detectado |
| Tiempo | Tiempo desde el último cambio de estado |
| Git | Resumen del estado Git |
| Puerto | Puerto reservado para la sesión |
| Tarea | Descripción dada al iniciar el chat |
| Aviso | Conflictos o situaciones que requieren atención |

Cerrar la ventana **no cierra el agente**. Permanece en la bandeja del sistema. Para detenerlo por completo usa **Salir** desde el icono de la bandeja.

## Estados y caducidad

Cuando una sesión está en `READY`, el panel la muestra como `LIBRE`. Si permanece inactiva durante el tiempo configurado pasa a `ABANDONADO`.

Valores predeterminados:

- `ABANDONADO`: tras 3 minutos en `READY`.
- Sesión limpia: puede liberarse tras 10 minutos.
- Sesión con cambios locales: espera 20 minutos.
- Sesiones trabajando (`BUILD`, `TEST`, `ADB`, `SERVER`, etc.): no caducan por tiempo mientras están activas.

Si el proceso que poseía una sesión desaparece, MultiChat puede liberar su slot, puerto y locks.

## Worktrees y seguridad Git

MultiChat no borra un worktree únicamente porque el chat haya terminado.

El panel calcula cuáles pueden limpiarse con seguridad. Un worktree solo se considera limpiable cuando no tiene cambios locales pendientes ni commits sin integrar.

Puedes usar:

- **Limpiar worktrees seguros** desde el panel.
- `Cleanup-Worktrees.ps1` para revisar.
- `Cleanup-Worktrees.ps1 -Apply` para aplicar la limpieza segura.

## Locks de recursos

`config.json` contiene reglas que detectan comandos que requieren exclusividad.

La configuración incluida protege, entre otros:

- ADB.
- fastboot.
- scrcpy.
- instalaciones APK/Gradle conectadas.
- emulador Android y herramientas relacionadas.

Si otro chat posee el lock correspondiente, la nueva operación no se ejecuta hasta evitar el conflicto.

## Puertos

Cada sesión puede reservar un puerto diferente. Por defecto se usa el rango que comienza en `3000` y dispone de 100 posiciones configurables.

Esto evita que dos chats intenten arrancar servidores de desarrollo en el mismo puerto.

## Configuración

Los valores principales están en `config.json`:

| Opción | Predeterminado | Función |
|---|---:|---|
| `maxSlots` | 8 | Máximo de chats gestionados |
| `refreshSeconds` | 1 | Refresco de información de chats |
| `abandonedAfterMinutes` | 3 | Tiempo hasta marcar una sesión como abandonada |
| `cleanExpireMinutes` | 10 | Caducidad de sesión limpia |
| `dirtyExpireMinutes` | 20 | Caducidad de sesión con cambios |
| `portRangeStart` | 3000 | Primer puerto reservable |
| `portRangeCount` | 100 | Tamaño del rango |
| `gitRefreshSeconds` | 5 | Frecuencia de comprobación Git |
| `historyLimit` | 50 | Máximo de entradas de historial |

Las reglas de recursos también se definen en este archivo mediante expresiones regulares.

## Archivos principales

| Archivo | Función |
|---|---|
| `ChatMulti.psm1` | Núcleo del gestor de sesiones |
| `Start-McpChatSession.ps1` | Crea y mantiene una sesión para un chat |
| `MultiChat-Tray.ps1` | Panel y agente de bandeja |
| `Setup.cmd` / `Setup.ps1` | Instalación local y acceso directo |
| `config.json` | Configuración portable |
| `PROMPT-PARA-CHATGPT.txt` | Instrucción lista para pegar en un chat |
| `SelfTest.cmd` / `SelfTest.ps1` | Comprobación del sistema |
| `Cleanup-Worktrees.ps1` | Limpieza segura de worktrees |
| `Show-History.ps1` | Consulta del historial |
| `Make-Portable-Package.ps1` | Genera el ZIP portable |

## Autocomprobación

Ejecuta:

```cmd
SelfTest.cmd
```

La prueba comprueba dependencias, sintaxis, configuración, slots, colores y reserva de puertos.

Resultado esperado:

```text
SELF-TEST: OK
Git, Node/npx, scripts, configuracion, slots, colores y puertos: OK.
```

## Portabilidad

El sistema usa rutas relativas a su propia carpeta y `Make-Portable-Package.ps1` genera un ZIP sin copiar el estado local, logs, sesiones ni worktrees del equipo donde se creó.

Para generar el paquete:

```powershell
.\Make-Portable-Package.ps1 -Version "2.0.0"
```

## Limitaciones

MultiChat coordina los procesos que **entran por el propio sistema MultiChat**. No puede impedir que una terminal externa, otro programa o un chat que ignore el gestor modifique directamente el mismo repositorio o recurso.

Por eso la regla más importante es: **un chat, una sesión persistente, un PID reutilizado durante todo el trabajo**.

## Desinstalación

1. Sal del agente desde el icono de la bandeja.
2. Borra el acceso directo del escritorio.
3. Borra la carpeta de ChatGPT MultiChat.

No instala servicios ni configura arranque automático.
