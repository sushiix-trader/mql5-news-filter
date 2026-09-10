//+------------------------------------------------------------------+
//|                                          QuickSortStructTRef.mqh |
//|                             Copyright 2021-2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

#define QS_STACK(S, N, B, E) S[N++] = ((long)(B) << 32) | (E)
#define QS_POP(S, N) S[--N]

//+------------------------------------------------------------------+
//| Templatized class for quick sorting of anything                  |
//+------------------------------------------------------------------+
template<typename T>
class QuickSortStructTRef
{
   long stack[]; // replacement for recursion in single-loop variant of sorting
   int size;     // actual count of elements in the stack
   #ifdef QS_INDEX
   int index[];  // indirect sorting
   #endif

 public:
   void Swap(T &array[], const int i, const int j)
   {
      if(i == j) return;
      const T temp = array[i];
      array[i] = array[j];
      array[j] = temp;
   }
   
   #ifdef QS_INDEX
   void SwapIdx(const int i, const int j)
   {
      if(i == j) return;
      const int tmp = index[i];
      index[i] = index[j];
      index[j] = tmp;
   }
   #endif
   
   // should override this with operator '>' equivalent
   // applied to any field of struct, object or array column
   virtual bool Compare(const T &a, const T &b) = 0;
   
   void QuickSort(T &array[], const int start = 0, int end = INT_MAX)
   {
      if(end == INT_MAX)
      {
         end = start + ArraySize(array) - 1;
      }
      if(start < end)
      {
         int pivot = start;
         Swap(array, (start + end) / 2 + 1, end); // eliminate slow-downs and minimize probability of stack-overflows for mostly sorted large arrays
   
         for(int i = start; i <= end; i++)
         {
            // use custom implementation of virtual Compare override
            if(!Compare(array[i], array[end]))
            {
               Swap(array, i, pivot++);
            }
         }
   
         --pivot;
   
         QuickSort(array, start, pivot - 1);
         QuickSort(array, pivot + 1, end);
      }
   }
   
 protected:
   void QuickSortRef(T &data[], const int start = 0, int end = INT_MAX)
   {
      if(end == INT_MAX)
      {
         end = start + ArraySize(data) - 1;
      }
      if(start < end)
      {
         int pivot = start;
         const int base = (start + end) / 2 + 1;
         #ifndef QS_INDEX
         Swap(data, base, end);
         #else
         SwapIdx(base, end);
         #endif
   
         for(int i = start; i <= end; i++)
         {
            // use custom implementation of virtual Compare override
            #ifndef QS_INDEX
            if(!Compare(data[i], data[end]))
            {
               Swap(data, i, pivot++);
            }
            #else
            if(!Compare(data[index[i]], data[index[end]]))
            {
               SwapIdx(i, pivot++);
            }
            #endif
         }
   
         --pivot;
   
         if(end > pivot + 1)
            QS_STACK(stack, size, pivot + 1, end);
         if(start < pivot - 1)
            QS_STACK(stack, size, start, pivot - 1);
      }
   }
   
 public:
   // this non-recursive sorting method guarantees no stack-overflows even on large arrays
   // in exchange to auxiliary memory used
   void QuickSortLoop(T &array[], const int start = 0, int end = INT_MAX)
   {
      const int n = ArraySize(array);
      if(ArrayResize(stack, n) < 1)  // worst/maximal case
      {
         PrintFormat("No data/memory to sort [%d] elements", n);
         return;
      }
      
      #ifdef QS_INDEX
      if(ArrayResize(index, n) < 1)
      {
         Print("No memory for index");
         return;
      }
      for(int i = 0; i < n; i++)
      {
         index[i] = i;
      }
      #endif
      
      size = 0;
      QS_STACK(stack, size, start, end);
      while(size && !IsStopped())
      {
         long range = QS_POP(stack, size);
         QuickSortRef(array, (int)(range >> 32), (int)(range & 0xFFFFFFFF));
      }
      
      #ifdef QS_INDEX
      T temp[];
      if(ArrayResize(temp, n) < 1)
      {
         Print("No memory for result");
         return;
      }
      for(int i = 0; i < n; i++)
      {
         temp[i] = array[index[i]];
      }
      ArraySwap(array, temp);
      #endif
   }
};

//+------------------------------------------------------------------+
//| Convenient macro to sort 'A'rray of 'T'ype by 'F'ield            |
//+------------------------------------------------------------------+
#define SORT_STRUCT(T,A,F)                                           \
{                                                                    \
   class InternalSort : public QuickSortStructTRef<T>                \
   {                                                                 \
      virtual bool Compare(const T &a, const T &b) override          \
      {                                                              \
         return a.##F > b.##F;                                       \
      }                                                              \
   } sort;                                                           \
   sort.QuickSort(A);                                                \
}

//+------------------------------------------------------------------+
//| Convenient macro to sort 'A'rray of 'T'ype by 'F'ield            |
//+------------------------------------------------------------------+
#define SORT_STRUCT_REF(T,A,F)                                       \
{                                                                    \
   class InternalSort : public QuickSortStructTRef<T>                \
   {                                                                 \
      virtual bool Compare(const T &a, const T &b) override          \
      {                                                              \
         return a.##F > b.##F;                                       \
      }                                                              \
   } sort;                                                           \
   sort.QuickSortLoop(A);                                            \
}

//+------------------------------------------------------------------+
//| Convenient macro to sort 'A'rray of 'T'ype by two 'F'ields       |
//+------------------------------------------------------------------+
#define SORT_STRUCT_REF_2(T,A,F1,F2)                                 \
{                                                                    \
   class InternalSort : public QuickSortStructTRef<T>                \
   {                                                                 \
      virtual bool Compare(const T &a, const T &b) override          \
      {                                                              \
         return (a.##F1 > b.##F1)                                    \
            || (a.##F1 == b.##F1 && a.##F2 > b.##F2);                \
      }                                                              \
   } sort;                                                           \
   sort.QuickSortLoop(A);                                            \
}

#undef QS_STACK
#undef QS_POP

//+------------------------------------------------------------------+
//| Example of macro usage to sort MqlRates struct by 'high' price   |
//+------------------------------------------------------------------+
// #define QS_INDEX // uncommented can possibly speed up sorting heavy structs, keep commented for simple structs
// QS_INDEX takes effect only if SORT_STRUCT_REF is used, SORT_STRUCT is unaffected
/*
   MqlRates rates[];
   CopyRates(_Symbol, _Period, 0, 10000, rates);
   SORT_STRUCT_REF(MqlRates, rates, high);
*/
