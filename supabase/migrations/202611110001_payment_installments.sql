-- NgontenYuk.co: dukungan pembayaran rental bertahap
-- Aman dijalankan ulang. Jalankan di Supabase SQL Editor setelah review.
BEGIN;

-- Sebelumnya satu rental hanya boleh memiliki satu pembayaran bertipe rental.
-- Hapus batasan itu agar satu transaksi dapat memiliki beberapa pembayaran.
DROP INDEX IF EXISTS public.one_rental_payment_per_rental;

-- Kunci baris rental saat validasi agar dua pembayaran bersamaan tidak dapat
-- membuat total pembayaran aktif melebihi harga sewa.
CREATE OR REPLACE FUNCTION public.validate_rental_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_rental_price numeric;
  v_reserved_total numeric;
BEGIN
  IF NEW.payment_type <> 'rental' THEN
    RETURN NEW;
  END IF;

  SELECT r.rental_price
    INTO v_rental_price
  FROM public.rentals r
  WHERE r.id = NEW.rental_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rental tidak ditemukan.'
      USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0)
    INTO v_reserved_total
  FROM public.payments p
  WHERE p.rental_id = NEW.rental_id
    AND p.payment_type = 'rental'
    AND p.payment_status IN ('pending', 'paid')
    AND p.id IS DISTINCT FROM NEW.id;

  -- Pembayaran pending ikut dicadangkan agar beberapa pembayaran yang
  -- belum dikonfirmasi tidak secara kolektif melampaui harga rental.
  IF NEW.payment_status IN ('pending', 'paid') THEN
    v_reserved_total := v_reserved_total + NEW.amount;
  END IF;

  IF v_reserved_total > v_rental_price THEN
    RAISE EXCEPTION
      'Total pembayaran aktif tidak boleh melebihi harga rental. Sisa yang dapat dicatat: %.',
      GREATEST(v_rental_price - (
        SELECT COALESCE(SUM(p.amount), 0)
        FROM public.payments p
        WHERE p.rental_id = NEW.rental_id
          AND p.payment_type = 'rental'
          AND p.payment_status IN ('pending', 'paid')
          AND p.id IS DISTINCT FROM NEW.id
      ), 0)
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE INDEX IF NOT EXISTS idx_payments_rental_status_created
  ON public.payments (rental_id, payment_status, created_at DESC);

COMMIT;
