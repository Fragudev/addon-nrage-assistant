# Guía de estilo de NRAGE (web + addon)

Esta guía recoge el estilo visual de la web de la guild (https://nrage.vercel.app) para que el addon
**NRAGE Assistant** se vea igual. La primera parte vale para cualquiera; la segunda traduce todo a un addon de WoW (Lua/XML).

---

## 1. La idea

**Fantasía oscura y agresiva, como una pantalla del propio juego.** Fondos casi negros con un tinte rojo,
un único color de marca (rojo sangre) **siempre con resplandor**, formas **angulares** como el logo
y detalles dorados para lo importante. Nada de colores pastel, degradados suaves de app moderna ni esquinas redondeadas.

Tres reglas que resumen todo:

1. **Negro + rojo que brilla.** El rojo nunca va "plano": lleva un halo rojo alrededor.
2. **Esquinas cortadas, no redondeadas.** Paneles y botones con las cuatro esquinas recortadas en diagonal.
3. **Dorado solo para lo especial.** Guild Master, victorias, avisos importantes, bordes de lo destacado.

---

## 2. Colores

| Nombre | Hex | RGB (0–255) | Uso |
| --- | --- | --- | --- |
| **Rojo NRAGE** | `#FF0019` | 255, 0, 25 | Color de marca: acentos, bordes activos, barras, palabras resaltadas. Siempre con resplandor. |
| Rojo vivo | `#FF3A2A` | 255, 58, 42 | Variante cálida para brillos y chispas. |
| Rojo profundo | `#7A000B` | 122, 0, 11 | Bordes discretos, inicio de degradados de barras. |
| Sangre | `#2A0006` | 42, 0, 6 | Rellenos oscuros con tinte rojo. |
| **Fondo** | `#030001` | 3, 0, 1 | Fondo general (negro con un toque rojo, nunca negro puro gris). |
| Panel | `#0C0203` | 12, 2, 3 | Fondo de ventanas y tarjetas. |
| Panel 2 | `#140405` | 20, 4, 5 | Panel más claro (parte superior de degradados). |
| Borde | `#3A0A10` | 58, 10, 16 | Bordes de campos y separadores. |
| Campo | `#050102` | 5, 1, 2 | Fondo de campos de texto y listas. |
| **Texto** | `#F4EBE8` | 244, 235, 232 | Texto principal (blanco cálido, no blanco puro). |
| Texto secundario | `#A8918D` | 168, 145, 141 | Descripciones, etiquetas, ayudas. |
| **Dorado** | `#F0B85A` | 240, 184, 90 | Guild Master, sellos ("Victoria"), destacados, títulos de jefe. |
| Arena | `#FFD9A8` | 255, 217, 168 | Texto pequeño sobre botones rojos. |
| Hielo | `#5CC8FF` | 92, 200, 255 | Solo para "el enemigo" / jefes (contraste fuego contra hielo). |
| Épico | `#B45CFF` | 180, 92, 255 | Dificultad heroica. |
| Conectado | `#45E07A` | 69, 224, 122 | Indicador "en línea". |

**Dificultades:** Normal `#6FD36F` · Heroico `#B45CFF` · Mítico `#FF8A1F`.
**Clases:** los colores oficiales de clase de WoW (en el addon, `RAID_CLASS_COLORS` / `C_ClassColor`).

**Resplandor rojo** (la firma visual): un halo de `#FF0019` al 45–70 % de opacidad alrededor del elemento.
En la web: `box-shadow: 0 0 30px rgba(255,0,25,.45)` y en textos `text-shadow: 0 0 24px rgba(255,0,25,.55)`.

**Degradado de botón principal:** de `#FF2236` (arriba) a `#C3000F` (abajo).
**Degradado de barras (vida, progreso):** de `#7A000B` (izquierda) a `#FF0019` y termina en `#FF7A5A`.

---

## 3. Tipografía

| Fuente | Peso | Uso | Cómo se escribe |
| --- | --- | --- | --- |
| **Cinzel** | Black (900) / Bold (700) | Títulos, nombres grandes, números grandes, sellos | Normalmente en MAYÚSCULAS, con resplandor rojo |
| **Barlow Condensed** | 400–700 (sobre todo SemiBold 600 y Bold 700) | Todo lo demás: botones, menús, etiquetas, texto | Etiquetas y botones en MAYÚSCULAS con **mucho espaciado entre letras** |

- Las dos son gratuitas (licencia SIL Open Font License), se pueden incluir en el addon: https://fonts.google.com/specimen/Cinzel y https://fonts.google.com/specimen/Barlow+Condensed
- **Espaciado de letras**: etiquetas pequeñas muy abiertas (equivale a 0,3–0,5 em, p. ej. `C A L E N D A R I O`); botones y menús 0,14–0,16 em; texto normal sin espaciado extra.
- **Palabra resaltada en títulos**: una o dos palabras clave en rojo NRAGE con resplandor (no en cursiva). Ej.: "Lo que se **avecina**."

Tamaños de referencia (web): título de sección 36–72 px · subtítulo 21 px · texto 18 px · botones 16 px · etiquetas 12–14 px.
En el addon, a escala: título 18–22, cabecera 14–16, texto 12–13, etiquetas 10–11.

---

## 4. Formas y componentes

### Esquinas cortadas
Todo panel, tarjeta, botón y ventana tiene las **4 esquinas recortadas en diagonal** (10 px en la web).
Forma: un octógono alargado. Los iconos importantes van en **hexágono** (como el emblema del botón de Discord)
y los números de pasos en **rombo**.

### Botón principal
- Relleno: degradado `#FF2236` → `#C3000F`.
- Texto: Barlow Condensed Bold, MAYÚSCULAS, espaciado 0,16 em, blanco.
- Resplandor rojo alrededor; al pasar el ratón, más brillo (+15 %).
- Versión destacada (Discord): marco interior dorado fino (1 px, `#FFD69A` al 55 %), emblema hexagonal oscuro con el icono y un destello blanco que lo cruza cada pocos segundos.

### Botón secundario
- Fondo rojo NRAGE al 6 % de opacidad + borde de 1 px rojo al 22 %.
- Al pasar el ratón: fondo al 16 %.

### Panel / ventana
- Fondo degradado de Panel 2 (`#140405`, arriba) a Panel (`#0C0203`, abajo).
- Borde de 1 px rojo al 22 % (`rgba(255,0,25,.22)`); destacado: borde rojo al 55–70 % + resplandor; muy especial: borde dorado.
- Un brillo rojo difuso en una esquina (opcional) da profundidad.

### Barra de progreso (estilo barra de experiencia)
- Fondo `#140204` con borde `#3A0610` y sombra interior negra.
- Relleno: degradado rojo profundo → rojo NRAGE → `#FF7A5A`, con resplandor.
- **Marcas verticales** negras cada 5 % (como la barra de XP de WoW).
- Etiqueta encima: MAYÚSCULAS pequeñas espaciadas, nombre a la izquierda y % a la derecha.

### Etiquetas de estado
Texto en MAYÚSCULAS 13 px, espaciado 0,16 em, con fondo del mismo color al 10 %:
Pendiente (dorado) · Aceptado (`#6FE08A`) · Rechazado (`#FF6A6A`) · Reserva (hielo).
**EN DIRECTO**: fondo rojo NRAGE, texto blanco y un punto blanco parpadeando.

### Sellos
Para momentos épicos ("VICTORIA", "JEFE DERROTADO"): Cinzel Black dorado, MAYÚSCULAS, espaciado 0,4 em,
dentro de un recuadro con borde dorado de 2 px y resplandor dorado.

### Cuenta atrás
Números grandes en Cinzel Black blancos con resplandor rojo, cada unidad en su propia caja con esquinas cortadas
y la unidad debajo en pequeño ("HORAS", "MIN", "SEG").

---

## 5. Imágenes y ambiente

- Ilustración de **cómic oscuro**: trazo de tinta negra grueso, sombreado plano, cielos rojo sangre con nubes en remolino,
  siluetas negras con pinchos y **brasas naranjas flotando**. Referencia: el castillo de la portada de la web.
- Encima de todo, un **grano** sutil (ruido al 7 % de opacidad) y viñeteado oscuro en los bordes.
- **Logo**: máscara negra con borde rojo; siempre con su resplandor rojo, nunca sobre fondos claros.

---

## 6. Tono del texto

Español de España, épico y directo, frases cortas, en segunda persona: "Gánate tu sitio.", "Tu leyenda empieza aquí.",
"Marca la fecha." Nada de tecnicismos ni tono corporativo.

---

## 7. Para el addon (WoW, Lua/XML)

### Colores en formato 0–1 (para `SetVertexColor`, `SetTextColor`, `SetBackdropColor`…)

```lua
NRAGE_COLORS = {
  red       = { 1.000, 0.000, 0.098 },  -- #FF0019 rojo NRAGE
  redHot    = { 1.000, 0.227, 0.165 },  -- #FF3A2A
  redDeep   = { 0.478, 0.000, 0.043 },  -- #7A000B
  blood     = { 0.165, 0.000, 0.024 },  -- #2A0006
  bg        = { 0.012, 0.000, 0.004 },  -- #030001 fondo
  panel     = { 0.047, 0.008, 0.012 },  -- #0C0203
  panel2    = { 0.078, 0.016, 0.020 },  -- #140405
  border    = { 0.227, 0.039, 0.063 },  -- #3A0A10
  field     = { 0.020, 0.004, 0.008 },  -- #050102
  text      = { 0.957, 0.922, 0.910 },  -- #F4EBE8
  muted     = { 0.659, 0.569, 0.553 },  -- #A8918D
  gold      = { 0.941, 0.722, 0.353 },  -- #F0B85A
  sand      = { 1.000, 0.851, 0.659 },  -- #FFD9A8
  ice       = { 0.361, 0.784, 1.000 },  -- #5CC8FF
  epic      = { 0.706, 0.361, 1.000 },  -- #B45CFF
  online    = { 0.271, 0.878, 0.478 },  -- #45E07A
  btnTop    = { 1.000, 0.133, 0.212 },  -- #FF2236
  btnBottom = { 0.765, 0.000, 0.059 },  -- #C3000F
}
-- Para texto con códigos de color: |cffff0019NRAGE|r · dorado |cfff0b85a…|r · secundario |cffa8918d…|r
```

Opacidades habituales: fondo de ventana 0.92–0.96 · borde normal rojo a 0.22 · borde destacado rojo a 0.6 · resplandor 0.45–0.7.

### Fuentes
- Incluir los `.ttf` en el addon (p. ej. `Media\Fonts\Cinzel-Black.ttf`, `Media\Fonts\BarlowCondensed-SemiBold.ttf`, `-Bold.ttf`).
- Títulos: `fs:SetFont("Interface\\AddOns\\NRAGE_Assistant\\Media\\Fonts\\Cinzel-Black.ttf", 18, "")` + sombra roja suave
  (`fs:SetShadowColor(1, 0, 0.1, 0.6)`, `fs:SetShadowOffset(0, 0)` o un segundo FontString desplazado si se quiere halo).
- Texto/UI: Barlow Condensed SemiBold 12–13; etiquetas en MAYÚSCULAS (WoW no espacia letras: para el efecto "espaciado"
  se pueden poner espacios finos o usar mayúsculas con un tamaño un punto menor).
- Si no se quieren fuentes propias: títulos con `Fonts\\MORPHEUS.TTF` (lo más parecido a Cinzel en el cliente) y texto con `Fonts\\FRIZQT__.TTF`.

### Esquinas cortadas y bordes
- WoW no recorta esquinas por código: usar una **textura de 9 trozos (9-slice)** con las esquinas en diagonal
  (`.tga` o `.blp`, tamaños potencia de 2, p. ej. 64×64 con esquinas de 10 px) para paneles y botones,
  o `BackdropTemplate` con un `edgeFile` propio que tenga las esquinas cortadas.
- Resplandor: una textura de brillo (`ADD` blend mode, `tex:SetBlendMode("ADD")`) teñida de rojo NRAGE detrás del marco.
- Emblemas e iconos destacados: máscara hexagonal (`MaskTexture`).

### Barras
- `StatusBar` con textura plana blanca teñida con un degradado (`tex:SetGradient("HORIZONTAL", CreateColor(0.478,0,0.043,1), CreateColor(1,0.478,0.353,1))`)
  y una textura superpuesta con marcas verticales negras cada 5 %.

### Logo
- Pedir el `logo.png` de la web (`public/assets/logo.png` del repo) y convertirlo a `.tga` o `.blp` de 128×128 o 256×256 con transparencia.

---

## 8. Resumen rápido

```
Fondo        #030001 / paneles #0C0203 → #140405
Marca        #FF0019 (siempre con halo rojo)
Destacado    #F0B85A (dorado)
Texto        #F4EBE8 / secundario #A8918D
Enemigo/jefe #5CC8FF (hielo)
Títulos      Cinzel Black, MAYÚSCULAS, halo rojo
UI           Barlow Condensed SemiBold/Bold, MAYÚSCULAS espaciadas
Formas       esquinas cortadas en diagonal, hexágonos, rombos; nada redondeado
```
