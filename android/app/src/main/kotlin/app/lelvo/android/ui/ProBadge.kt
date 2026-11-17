package app.lelvo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Gold “PRO” pill (Ente-style). Marks Pro features in Collections, Settings and Locked Folder. */
@Composable
fun ProBadge(modifier: Modifier = Modifier) {
    Text(
        "PRO",
        modifier = modifier
            .background(
                Brush.linearGradient(listOf(Color(0xFFF5D76E), Color(0xFFC9A227))),
                RoundedCornerShape(4.dp),
            )
            .padding(horizontal = 6.dp, vertical = 2.dp)
            .semantics { contentDescription = "Pro" },
        color = Color(0xFF3D2F00),
        fontSize = 10.sp,
        fontWeight = FontWeight.Black,
        letterSpacing = 0.5.sp,
    )
}
