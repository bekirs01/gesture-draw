package com.benimapp.gesture.data

import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query

/**
 * desktop-cizim projesi Supabase REST API
 * https://github.com/bekirs01/desktop-cizim
 */
interface SupabaseApi {

    @GET("pdf_page_strokes")
    suspend fun getPageStrokes(
        @Query("share_token") shareTokenFilter: String,
        @Query("page_num") pageNumFilter: String,
        @Query("select") select: String = "strokes"
    ): Response<List<PdfPageStrokesRow>>

    @POST("pdf_page_strokes")
    suspend fun upsertPageStrokes(
        @Body body: PdfPageStrokesUpsert
    ): Response<Unit>

    @DELETE("pdf_page_strokes")
    suspend fun deletePageStrokes(
        @Query("share_token") shareToken: String,
        @Query("page_num") pageNum: Int
    ): Response<Unit>
}

/** Supabase pdf_page_strokes satırı */
data class PdfPageStrokesRow(
    val share_token: String,
    val page_num: Int,
    val strokes: List<StrokeData>,
    val updated_at: String?
)

/** Upsert için body */
data class PdfPageStrokesUpsert(
    val share_token: String,
    val page_num: Int,
    val strokes: List<StrokeData>,
    val updated_at: String
)

/** Stroke formatı - desktop-cizim ile uyumlu */
data class StrokeData(
    val points: List<PointData>,
    val color: String = "#00ff9f",
    val lineWidth: Int = 4
)

data class PointData(
    val x: Float,
    val y: Float
)
